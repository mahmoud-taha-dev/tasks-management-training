import { serve } from "https://deno.land/std/http/server.ts";
import { SMTPClient } from "https://deno.land/x/denomailer/mod.ts";
serve(async (req) => {
  try {
    const { email, invite_link } = await req.json();
    const GMAIL_USER = "your-email@gmail.com";
    const GMAIL_APP_PASSWORD = "your-app-password";
    const client = new SMTPClient({
      connection: {
        hostname: "smtp.gmail.com",
        port: 465,
        tls: true,
        auth: {
          username: GMAIL_USER,
          password: GMAIL_APP_PASSWORD,
        },
      },
    });
    await client.send({
      from: GMAIL_USER,
      to: email,
      subject: "You're invited to a project 🚀",
      html: `
    <h2>You're invited!</h2>
    <p>Click below to join the project:</p>
    <a href="${invite_link}">Accept Invitation</a>
  `,
    });
    await client.close();
    return new Response(
      JSON.stringify({
        success: true,
      }),
      {
        status: 200,
        headers: {
          "Content-Type": "application/json",
        },
      },
    );
  } catch (err) {
    console.error(err);
    return new Response(
      JSON.stringify({
        error: err.message,
      }),
      {
        status: 500,
      },
    );
  }
});
