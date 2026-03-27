


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."task_status" AS ENUM (
    'TO_DO',
    'IN_PROGRESS',
    'BLOCKED',
    'IN_REVIEW',
    'READY_FOR_QA',
    'REOPENED',
    'READY_FOR_PRODUCTION',
    'DONE'
);


ALTER TYPE "public"."task_status" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."accept_invitation"("p_token" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_invite record;
BEGIN
  SELECT * INTO v_invite
  FROM project_invitations
  WHERE token = p_token;

  IF v_invite IS NULL THEN
    RAISE EXCEPTION 'Invalid invitation';
  END IF;

  IF v_invite.expires_at < now() THEN
    UPDATE project_invitations
    SET status = 'expired'
    WHERE id = v_invite.id;

    RAISE EXCEPTION 'Invitation expired';
  END IF;

  -- Add user to project
  INSERT INTO project_members (project_id, user_id, role)
  VALUES (v_invite.project_id, auth.uid(), 'member')
  ON CONFLICT DO NOTHING;

  -- Mark accepted
  UPDATE project_invitations
  SET status = 'accepted'
  WHERE id = v_invite.id;
END;
$$;


ALTER FUNCTION "public"."accept_invitation"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."add_project_owner"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  insert into project_members (project_id, user_id, role)
  values (new.id, auth.uid(), 'owner');
  return new;
end;
$$;


ALTER FUNCTION "public"."add_project_owner"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_project_epic_id"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  next_number integer;
BEGIN
  -- Ensure counter exists for the project
  INSERT INTO project_epic_counters (project_id)
  VALUES (NEW.project_id)
  ON CONFLICT (project_id) DO NOTHING;

  -- Increment counter safely
  UPDATE project_epic_counters
  SET last_number = last_number + 1
  WHERE project_id = NEW.project_id
  RETURNING last_number INTO next_number;

  -- Assign readable epic id
  NEW.epic_id := 'EPIC-' || next_number;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."generate_project_epic_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_project_task_id"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  next_number integer;
BEGIN
  -- Ensure counter exists for the project
  INSERT INTO project_task_counters (project_id)
  VALUES (NEW.project_id)
  ON CONFLICT (project_id) DO NOTHING;

  -- Increment counter safely
  UPDATE project_task_counters
  SET last_number = last_number + 1
  WHERE project_id = NEW.project_id
  RETURNING last_number INTO next_number;

  NEW.task_id := 'TASK-' || next_number;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."generate_project_task_id"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."projects" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "created_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."projects" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_projects"() RETURNS SETOF "public"."projects"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  return query
  select p.*
  from projects p
  join project_members pm on pm.project_id = p.id
  where pm.user_id = auth.uid();
end;
$$;


ALTER FUNCTION "public"."get_projects"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."invite_member"("p_email" "text", "p_project_id" "uuid", "p_app_url" "text", "p_base_url" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_token text;
BEGIN
  -- Check if inviter is member
  IF NOT EXISTS (
    SELECT 1 FROM project_members
    WHERE project_id = p_project_id
      AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  -- Generate token
  v_token := encode(gen_random_bytes(32), 'hex');

  -- Insert invitation
  INSERT INTO project_invitations (
    project_id,
    email,
    token,
    invited_by,
    expires_at
  )
  VALUES (
    p_project_id,
    p_email,
    v_token,
    auth.uid(),
    now() + interval '2 days'
  );

  -- Call edge function to send email
  PERFORM net.http_post(
    url := p_base_url || '/functions/v1/send-invite-email',
    headers := jsonb_build_object(
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object(
      'email', p_email,
      'invite_link', p_app_url || '/invite?token=' || v_token
    )
  );
END;
$$;


ALTER FUNCTION "public"."invite_member"("p_email" "text", "p_project_id" "uuid", "p_app_url" "text", "p_base_url" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."attachments" (
    "id" bigint NOT NULL,
    "project_id" bigint,
    "task_id" bigint,
    "epic_id" bigint,
    "uploaded_by" "uuid",
    "url" "text" NOT NULL,
    "file_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."attachments" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."attachments_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."attachments_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."attachments_id_seq" OWNED BY "public"."attachments"."id";



CREATE TABLE IF NOT EXISTS "public"."comments" (
    "id" bigint NOT NULL,
    "project_id" bigint,
    "task_id" bigint,
    "epic_id" bigint,
    "author" "uuid",
    "content" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."comments" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."comments_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."comments_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."comments_id_seq" OWNED BY "public"."comments"."id";



CREATE TABLE IF NOT EXISTS "public"."departments" (
    "id" bigint NOT NULL,
    "name" "text" NOT NULL
);


ALTER TABLE "public"."departments" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."departments_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."departments_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."departments_id_seq" OWNED BY "public"."departments"."id";



CREATE TABLE IF NOT EXISTS "public"."epics" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "created_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "assignee_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "deadline" "date",
    "epic_id" "text"
);


ALTER TABLE "public"."epics" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_members" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "project_members_role_check" CHECK (("role" = ANY (ARRAY['owner'::"text", 'admin'::"text", 'member'::"text", 'viewer'::"text"])))
);


ALTER TABLE "public"."project_members" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."get_project_members" AS
 SELECT "pm"."id" AS "member_id",
    "pm"."project_id",
    "pm"."user_id",
    "pm"."role",
    "u"."email",
    "u"."raw_user_meta_data" AS "metadata"
   FROM ("public"."project_members" "pm"
     JOIN "auth"."users" "u" ON (("pm"."user_id" = "u"."id")));


ALTER VIEW "public"."get_project_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "name" "text",
    "email" "text",
    "department" "text",
    "avatar_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_epic_counters" (
    "project_id" "uuid" NOT NULL,
    "last_number" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."project_epic_counters" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."project_epics" AS
 SELECT "e"."id",
    "e"."project_id",
    "e"."title",
    "e"."description",
    "e"."created_at",
    "e"."deadline",
    "e"."epic_id",
    "jsonb_build_object"('sub', "cu"."id", 'name', ("cu"."raw_user_meta_data" ->> 'name'::"text"), 'email', "cu"."email", 'department', ("cu"."raw_user_meta_data" ->> 'department'::"text")) AS "created_by",
    "jsonb_build_object"('sub', "au"."id", 'name', ("au"."raw_user_meta_data" ->> 'name'::"text"), 'email', "au"."email", 'department', ("au"."raw_user_meta_data" ->> 'department'::"text")) AS "assignee"
   FROM (("public"."epics" "e"
     LEFT JOIN "auth"."users" "cu" ON (("cu"."id" = "e"."created_by")))
     LEFT JOIN "auth"."users" "au" ON (("au"."id" = "e"."assignee_id")));


ALTER VIEW "public"."project_epics" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_invitations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "token" "text" NOT NULL,
    "invited_by" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text",
    "expires_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."project_invitations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_task_counters" (
    "project_id" "uuid" NOT NULL,
    "last_number" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."project_task_counters" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tasks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "epic_id" "uuid",
    "project_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "created_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "assignee_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "due_date" timestamp with time zone,
    "status" "public"."task_status" DEFAULT 'TO_DO'::"public"."task_status" NOT NULL,
    "task_id" "text"
);


ALTER TABLE "public"."tasks" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."project_tasks" AS
 SELECT "t"."id",
    "t"."project_id",
    "t"."epic_id",
    "t"."title",
    "t"."description",
    "t"."status",
    "t"."created_at",
    "t"."due_date",
    "t"."task_id",
    "jsonb_build_object"('id', "e"."id", 'epic_id', "e"."epic_id", 'title', "e"."title") AS "epic",
    "jsonb_build_object"('id', "cb"."id", 'name', ("cb"."raw_user_meta_data" ->> 'name'::"text"), 'email', "cb"."email", 'department', ("cb"."raw_user_meta_data" ->> 'department'::"text")) AS "created_by",
    "jsonb_build_object"('id', "a"."id", 'name', ("a"."raw_user_meta_data" ->> 'name'::"text"), 'email', "a"."email", 'department', ("a"."raw_user_meta_data" ->> 'department'::"text")) AS "assignee"
   FROM ((("public"."tasks" "t"
     LEFT JOIN "public"."epics" "e" ON (("e"."id" = "t"."epic_id")))
     LEFT JOIN "auth"."users" "cb" ON (("cb"."id" = "t"."created_by")))
     LEFT JOIN "auth"."users" "a" ON (("a"."id" = "t"."assignee_id")));


ALTER VIEW "public"."project_tasks" OWNER TO "postgres";


ALTER TABLE ONLY "public"."attachments" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."attachments_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."comments" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."comments_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."departments" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."departments_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."attachments"
    ADD CONSTRAINT "attachments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."departments"
    ADD CONSTRAINT "departments_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."departments"
    ADD CONSTRAINT "departments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."epics"
    ADD CONSTRAINT "epics_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."epics"
    ADD CONSTRAINT "epics_project_epic_unique" UNIQUE ("project_id", "epic_id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_epic_counters"
    ADD CONSTRAINT "project_epic_counters_pkey" PRIMARY KEY ("project_id");



ALTER TABLE ONLY "public"."project_invitations"
    ADD CONSTRAINT "project_invitations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_invitations"
    ADD CONSTRAINT "project_invitations_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."project_members"
    ADD CONSTRAINT "project_members_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_task_counters"
    ADD CONSTRAINT "project_task_counters_pkey" PRIMARY KEY ("project_id");



ALTER TABLE ONLY "public"."projects"
    ADD CONSTRAINT "projects_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_project_task_unique" UNIQUE ("project_id", "task_id");



CREATE OR REPLACE TRIGGER "add_project_owner_trigger" AFTER INSERT ON "public"."projects" FOR EACH ROW EXECUTE FUNCTION "public"."add_project_owner"();



CREATE OR REPLACE TRIGGER "epics_generate_project_epic_id" BEFORE INSERT ON "public"."epics" FOR EACH ROW WHEN (("new"."epic_id" IS NULL)) EXECUTE FUNCTION "public"."generate_project_epic_id"();



CREATE OR REPLACE TRIGGER "tasks_generate_project_task_id" BEFORE INSERT ON "public"."tasks" FOR EACH ROW WHEN (("new"."task_id" IS NULL)) EXECUTE FUNCTION "public"."generate_project_task_id"();



ALTER TABLE ONLY "public"."attachments"
    ADD CONSTRAINT "attachments_uploaded_by_fkey" FOREIGN KEY ("uploaded_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_author_fkey" FOREIGN KEY ("author") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."epics"
    ADD CONSTRAINT "epics_assignee_id_fkey" FOREIGN KEY ("assignee_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."epics"
    ADD CONSTRAINT "epics_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."epics"
    ADD CONSTRAINT "epics_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_invitations"
    ADD CONSTRAINT "project_invitations_invited_by_fkey" FOREIGN KEY ("invited_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."project_invitations"
    ADD CONSTRAINT "project_invitations_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_members"
    ADD CONSTRAINT "project_members_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_members"
    ADD CONSTRAINT "project_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."projects"
    ADD CONSTRAINT "projects_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_assignee_id_fkey" FOREIGN KEY ("assignee_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_epic_id_fkey" FOREIGN KEY ("epic_id") REFERENCES "public"."epics"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE "public"."attachments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "attachments_delete" ON "public"."attachments" FOR DELETE USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "attachments_insert" ON "public"."attachments" FOR INSERT WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "attachments_select" ON "public"."attachments" FOR SELECT USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "attachments_update" ON "public"."attachments" FOR UPDATE USING (("auth"."uid"() IS NOT NULL));



ALTER TABLE "public"."comments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "comments_delete" ON "public"."comments" FOR DELETE USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "comments_insert" ON "public"."comments" FOR INSERT WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "comments_select" ON "public"."comments" FOR SELECT USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "comments_update" ON "public"."comments" FOR UPDATE USING (("auth"."uid"() IS NOT NULL));



ALTER TABLE "public"."departments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "departments_delete" ON "public"."departments" FOR DELETE USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "departments_insert" ON "public"."departments" FOR INSERT WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "departments_select" ON "public"."departments" FOR SELECT USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "departments_update" ON "public"."departments" FOR UPDATE USING (("auth"."uid"() IS NOT NULL));



ALTER TABLE "public"."epics" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "epics_delete" ON "public"."epics" FOR DELETE USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "epics_insert" ON "public"."epics" FOR INSERT WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "epics_select" ON "public"."epics" FOR SELECT USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "epics_update" ON "public"."epics" FOR UPDATE USING (("auth"."uid"() IS NOT NULL));



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_delete" ON "public"."profiles" FOR DELETE USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "profiles_insert" ON "public"."profiles" FOR INSERT WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "profiles_select" ON "public"."profiles" FOR SELECT USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "profiles_update" ON "public"."profiles" FOR UPDATE USING (("auth"."uid"() IS NOT NULL));



ALTER TABLE "public"."project_members" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "project_members_delete" ON "public"."project_members" FOR DELETE USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "project_members_insert" ON "public"."project_members" FOR INSERT WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "project_members_select" ON "public"."project_members" FOR SELECT USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "project_members_update" ON "public"."project_members" FOR UPDATE USING (("auth"."uid"() IS NOT NULL));



ALTER TABLE "public"."projects" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "projects_delete" ON "public"."projects" FOR DELETE USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "projects_insert" ON "public"."projects" FOR INSERT WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "projects_select" ON "public"."projects" FOR SELECT USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "projects_update" ON "public"."projects" FOR UPDATE USING (("auth"."uid"() IS NOT NULL));



ALTER TABLE "public"."tasks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tasks_delete" ON "public"."tasks" FOR DELETE USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "tasks_insert" ON "public"."tasks" FOR INSERT WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "tasks_select" ON "public"."tasks" FOR SELECT USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "tasks_update" ON "public"."tasks" FOR UPDATE USING (("auth"."uid"() IS NOT NULL));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";




























































































































































GRANT ALL ON FUNCTION "public"."accept_invitation"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."accept_invitation"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."accept_invitation"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."add_project_owner"() TO "anon";
GRANT ALL ON FUNCTION "public"."add_project_owner"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_project_owner"() TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_project_epic_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."generate_project_epic_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_project_epic_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_project_task_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."generate_project_task_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_project_task_id"() TO "service_role";



GRANT ALL ON TABLE "public"."projects" TO "anon";
GRANT ALL ON TABLE "public"."projects" TO "authenticated";
GRANT ALL ON TABLE "public"."projects" TO "service_role";



GRANT ALL ON FUNCTION "public"."get_projects"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_projects"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_projects"() TO "service_role";



GRANT ALL ON FUNCTION "public"."invite_member"("p_email" "text", "p_project_id" "uuid", "p_app_url" "text", "p_base_url" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."invite_member"("p_email" "text", "p_project_id" "uuid", "p_app_url" "text", "p_base_url" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."invite_member"("p_email" "text", "p_project_id" "uuid", "p_app_url" "text", "p_base_url" "text") TO "service_role";


















GRANT ALL ON TABLE "public"."attachments" TO "anon";
GRANT ALL ON TABLE "public"."attachments" TO "authenticated";
GRANT ALL ON TABLE "public"."attachments" TO "service_role";



GRANT ALL ON SEQUENCE "public"."attachments_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."attachments_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."attachments_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."comments" TO "anon";
GRANT ALL ON TABLE "public"."comments" TO "authenticated";
GRANT ALL ON TABLE "public"."comments" TO "service_role";



GRANT ALL ON SEQUENCE "public"."comments_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."comments_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."comments_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."departments" TO "anon";
GRANT ALL ON TABLE "public"."departments" TO "authenticated";
GRANT ALL ON TABLE "public"."departments" TO "service_role";



GRANT ALL ON SEQUENCE "public"."departments_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."departments_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."departments_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."epics" TO "anon";
GRANT ALL ON TABLE "public"."epics" TO "authenticated";
GRANT ALL ON TABLE "public"."epics" TO "service_role";



GRANT ALL ON TABLE "public"."project_members" TO "anon";
GRANT ALL ON TABLE "public"."project_members" TO "authenticated";
GRANT ALL ON TABLE "public"."project_members" TO "service_role";



GRANT ALL ON TABLE "public"."get_project_members" TO "anon";
GRANT ALL ON TABLE "public"."get_project_members" TO "authenticated";
GRANT ALL ON TABLE "public"."get_project_members" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."project_epic_counters" TO "anon";
GRANT ALL ON TABLE "public"."project_epic_counters" TO "authenticated";
GRANT ALL ON TABLE "public"."project_epic_counters" TO "service_role";



GRANT ALL ON TABLE "public"."project_epics" TO "anon";
GRANT ALL ON TABLE "public"."project_epics" TO "authenticated";
GRANT ALL ON TABLE "public"."project_epics" TO "service_role";



GRANT ALL ON TABLE "public"."project_invitations" TO "anon";
GRANT ALL ON TABLE "public"."project_invitations" TO "authenticated";
GRANT ALL ON TABLE "public"."project_invitations" TO "service_role";



GRANT ALL ON TABLE "public"."project_task_counters" TO "anon";
GRANT ALL ON TABLE "public"."project_task_counters" TO "authenticated";
GRANT ALL ON TABLE "public"."project_task_counters" TO "service_role";



GRANT ALL ON TABLE "public"."tasks" TO "anon";
GRANT ALL ON TABLE "public"."tasks" TO "authenticated";
GRANT ALL ON TABLE "public"."tasks" TO "service_role";



GRANT ALL ON TABLE "public"."project_tasks" TO "anon";
GRANT ALL ON TABLE "public"."project_tasks" TO "authenticated";
GRANT ALL ON TABLE "public"."project_tasks" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































