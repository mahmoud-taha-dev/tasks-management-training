import { createClient } from "npm:@supabase/supabase-js@2.95.0";
import { SMTPClient } from "https://deno.land/x/denomailer/mod.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type InvitationRequest = {
  project_id?: string;
  email?: string;
  role?: "admin" | "member" | "viewer";
};

type CreatedInvitation = {
  invitation_id: string;
  project_id: string;
  email: string;
  role: string;
  status: string;
  expires_at: string;
  invitation_token: string;
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  let invitationId: string | undefined;
  let supabase: ReturnType<typeof createClient> | undefined;
  let smtpClient: SMTPClient | undefined;

  try {
    const origin = req.headers.get("Origin");
    if (!origin) {
      return jsonResponse({ error: "The Origin header is required to generate the invitation link" }, 400);
    }

    let frontendOrigin: URL;
    try {
      frontendOrigin = new URL(origin);
    } catch {
      return jsonResponse({ error: "The Origin header is invalid" }, 400);
    }

    if (frontendOrigin.protocol !== "http:" && frontendOrigin.protocol !== "https:") {
      return jsonResponse({ error: "The Origin header must use HTTP or HTTPS" }, 400);
    }

    const authorization = req.headers.get("Authorization");
    if (!authorization?.startsWith("Bearer ")) {
      return jsonResponse({ error: "Authentication is required" }, 401);
    }

    const supabaseUrl = requiredEnv("SUPABASE_URL");
    const supabaseAnonKey =
      Deno.env.get("SUPABASE_ANON_KEY") ??
      Deno.env.get("SUPABASE_PUBLISHABLE_KEY");

    if (!supabaseAnonKey) {
      throw new Error("Missing SUPABASE_ANON_KEY or SUPABASE_PUBLISHABLE_KEY");
    }

    // Gmail SMTP configuration is fixed; only account credentials are project secrets.
    const smtpHost = "smtp.gmail.com";
    const smtpPort = 465;
    const smtpUser = requiredEnv("SMTP_USER");
    const smtpFrom = Deno.env.get("SMTP_FROM")?.trim() || smtpUser;
    const smtpPassword = requiredEnv("SMTP_PASSWORD");
    const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");

    if (!Number.isInteger(smtpPort) || smtpPort <= 0 || smtpPort > 65535) {
      throw new Error("SMTP_PORT must be a valid TCP port");
    }

    supabase = createClient(supabaseUrl, supabaseAnonKey, {
      auth: { autoRefreshToken: false, persistSession: false },
      global: { headers: { Authorization: authorization } },
    });

    const token = authorization.slice("Bearer ".length).trim();
    const { data: authData, error: authError } = await supabase.auth.getUser(token);
    if (authError || !authData.user) {
      return jsonResponse({ error: "Invalid or expired access token" }, 401);
    }

    let body: InvitationRequest;
    try {
      body = await req.json();
    } catch {
      return jsonResponse({ error: "Request body must be valid JSON" }, 400);
    }

    const projectId = body.project_id?.trim();
    const email = body.email?.trim();
    const role = body.role ?? "member";

    if (!projectId) return jsonResponse({ error: "project_id is required" }, 400);
    if (!email) return jsonResponse({ error: "email is required" }, 400);
    if (!["admin", "member", "viewer"].includes(role)) {
      return jsonResponse({ error: "role must be admin, member, or viewer" }, 400);
    }

    const invitationService = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: invitationData, error: invitationError } = await invitationService.rpc(
      "create_project_invitation",
      {
        p_project_id: projectId,
        p_email: email,
        p_role: role,
        p_invited_by: authData.user.id,
      },
    );

    if (invitationError) {
      console.error("Invitation creation failed:", invitationError.message);
      return jsonResponse({ error: invitationError.message }, 400);
    }

    const invitation = invitationData as CreatedInvitation;
    invitationId = invitation.invitation_id;

    const invitationUrl = new URL("/accept-invitation", frontendOrigin.origin);
    invitationUrl.searchParams.set("token", invitation.invitation_token);
    const inviteLink = invitationUrl.toString();

    smtpClient = new SMTPClient({
      connection: {
        hostname: smtpHost,
        port: smtpPort,
        tls: smtpPort === 465,
        auth: {
          username: smtpUser,
          password: smtpPassword,
        },
      },
    });

    await smtpClient.send({
      from: smtpFrom,
      to: invitation.email,
      subject: "You're invited to a project",
      html: `
        <h2>You're invited!</h2>
        <p>You have been invited to join a project on Taskly.</p>
        <p><a href="${escapeHtml(inviteLink)}">Accept Invitation</a></p>
        <p>This invitation expires in 7 days.</p>
      `,
    });

    try {
      await smtpClient.close();
    } catch (closeError) {
      console.error("Email was sent, but SMTP connection close failed:", closeError);
    }
    smtpClient = undefined;

    return jsonResponse({
      success: true,
      invitation: {
        id: invitation.invitation_id,
        project_id: invitation.project_id,
        email: invitation.email,
        role: invitation.role,
        status: invitation.status,
        expires_at: invitation.expires_at,
      },
    });
  } catch (error) {
    console.error("send-invite-email failed:", error instanceof Error ? error.message : "Unknown error");

    if (smtpClient) {
      try {
        await smtpClient.close();
      } catch (closeError) {
        console.error("Failed to close SMTP connection:", closeError);
      }
    }

    if (invitationId && supabase) {
      const { error: revokeError } = await supabase.rpc("revoke_project_invitation", {
        p_invitation_id: invitationId,
      });
      if (revokeError) {
        console.error("Failed to revoke undelivered invitation:", revokeError.message);
      }
    }

    return jsonResponse({ error: "Unable to send the project invitation" }, 500);
  }
});
