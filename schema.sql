-- Taskly database schema redesign
-- Fresh-install schema for Supabase/PostgreSQL.
-- Date-based task statistics use UTC consistently.
-- Apply to a new database/project. This is not a data-preserving migration.

begin;

create extension if not exists pgcrypto with schema extensions;

create type public.task_status as enum (
  'TO_DO',
  'IN_PROGRESS',
  'BLOCKED',
  'IN_REVIEW',
  'READY_FOR_QA',
  'REOPENED',
  'READY_FOR_PRODUCTION',
  'DONE'
);

create table public.projects (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) > 0),
  description text,
  created_by uuid not null default auth.uid() references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.project_members (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner', 'admin', 'member', 'viewer')),
  created_at timestamptz not null default now(),
  constraint project_members_project_user_key unique (project_id, user_id)
);

create table public.project_invitations (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  email text not null check (length(btrim(email)) > 0),
  token_hash text not null unique,
  invited_by uuid not null references auth.users(id) on delete restrict,
  role text not null default 'member' check (role in ('admin', 'member', 'viewer')),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'expired', 'revoked')),
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  accepted_at timestamptz
);

create unique index project_invitations_one_pending_per_email
  on public.project_invitations (project_id, lower(email))
  where status = 'pending';

create table public.epics (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  title text not null check (length(btrim(title)) > 0),
  description text,
  created_by uuid not null default auth.uid() references auth.users(id) on delete restrict,
  assignee_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deadline date,
  epic_number bigint not null,
  constraint epics_project_number_key unique (project_id, epic_number),
  constraint epics_project_id_id_key unique (project_id, id)
);

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  epic_id uuid,
  title text not null check (length(btrim(title)) > 0),
  description text,
  created_by uuid not null default auth.uid() references auth.users(id) on delete restrict,
  assignee_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  due_date timestamptz,
  status public.task_status not null default 'TO_DO',
  task_number bigint not null,
  constraint tasks_project_number_key unique (project_id, task_number),
  constraint tasks_project_id_id_key unique (project_id, id),
  constraint tasks_epic_same_project_fkey
    foreign key (project_id, epic_id) references public.epics(project_id, id)
    on delete set null (epic_id)
);

create index tasks_project_status_idx on public.tasks (project_id, status);
create index tasks_assignee_due_date_idx on public.tasks (assignee_id, due_date) where due_date is not null;
create index tasks_project_epic_idx on public.tasks (project_id, epic_id);
create index epics_project_idx on public.epics (project_id);
create index project_members_user_project_idx on public.project_members (user_id, project_id);

-- Keep per-project readable identifiers concurrency-safe without exposing counters.
create table public.project_task_counters (
  project_id uuid primary key references public.projects(id) on delete cascade,
  last_number bigint not null default 0 check (last_number >= 0)
);

create table public.project_epic_counters (
  project_id uuid primary key references public.projects(id) on delete cascade,
  last_number bigint not null default 0 check (last_number >= 0)
);

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;

create or replace function private.has_project_role(
  p_project_id uuid,
  p_allowed_roles text[]
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.project_members pm
    where pm.project_id = p_project_id
      and pm.user_id = (select auth.uid())
      and pm.role = any (p_allowed_roles)
  );
$$;

revoke all on function private.has_project_role(uuid, text[]) from public, anon;
grant execute on function private.has_project_role(uuid, text[]) to authenticated;


-- Free the one-pending-invitation slot when its previous invitation has expired.
create or replace function private.expire_old_project_invitation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.project_invitations
    set status = 'expired'
    where project_id = new.project_id
      and lower(email) = lower(btrim(new.email))
      and status = 'pending'
      and expires_at <= now();
  return new;
end;
$$;

revoke all on function private.expire_old_project_invitation() from public, anon, authenticated;
create trigger project_invitations_expire_old_before_insert
before insert on public.project_invitations
for each row execute function private.expire_old_project_invitation();

-- Create invitations for any email address; the invitee need not already have an Auth account.
-- Only the SHA-256 hash is stored. The raw token is returned once to the authorized inviter
-- for delivery through the application's trusted email service.
create or replace function public.create_project_invitation(
  p_project_id uuid,
  p_email text,
  p_role text default 'member',
  p_invited_by uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := p_invited_by;
  v_email text := lower(btrim(p_email));
  v_role text := coalesce(p_role, 'member');
  v_token text;
  v_expires_at timestamptz := now() + interval '7 days';
  v_invitation_id uuid;
  v_is_owner_or_admin boolean;
  v_is_owner boolean;
begin
  -- Only the trusted Edge Function may call this RPC with its service-role client.
  if (select auth.jwt() ->> 'role') is distinct from 'service_role' then
    raise exception 'This function can only be called by the invitation service' using errcode = '42501';
  end if;
  if v_user_id is null then
    raise exception 'Inviter user ID is required' using errcode = '22004';
  end if;
  if p_project_id is null then
    raise exception 'Project ID is required' using errcode = '22004';
  end if;
  if v_email is null or length(v_email) > 320
     or position('@' in v_email) <= 1 or v_email ~ '[[:space:]]' then
    raise exception 'A valid email address is required' using errcode = '22023';
  end if;
  if v_role not in ('admin', 'member', 'viewer') then
    raise exception 'Invalid invitation role' using errcode = '22023';
  end if;

  select
    coalesce(bool_or(pm.role in ('owner', 'admin')), false),
    coalesce(bool_or(pm.role = 'owner'), false)
  into v_is_owner_or_admin, v_is_owner
  from public.project_members pm
  where pm.project_id = p_project_id and pm.user_id = v_user_id;

  if not v_is_owner_or_admin then
    raise exception 'Only project owners and admins can invite members' using errcode = '42501';
  end if;
  if v_role = 'admin' and not v_is_owner then
    raise exception 'Only project owners can invite admins' using errcode = '42501';
  end if;
  if exists (
    select 1 from public.project_members pm
    join auth.users u on u.id = pm.user_id
    where pm.project_id = p_project_id and lower(u.email) = v_email
  ) then
    raise exception 'This email already belongs to a project member' using errcode = '23505';
  end if;

  update public.project_invitations
     set status = 'expired'
   where project_id = p_project_id and lower(email) = v_email
     and status = 'pending' and expires_at <= now();

  if exists (
    select 1 from public.project_invitations i
    where i.project_id = p_project_id and lower(i.email) = v_email
      and i.status = 'pending' and i.expires_at > now()
  ) then
    raise exception 'A pending invitation already exists for this email' using errcode = '23505';
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.project_invitations (
    project_id, email, token_hash, invited_by, role, expires_at
  ) values (
    p_project_id, v_email,
    encode(extensions.digest(convert_to(v_token, 'UTF8'), 'sha256'), 'hex'),
    v_user_id, v_role, v_expires_at
  ) returning id into v_invitation_id;

  return jsonb_build_object(
    'invitation_id', v_invitation_id, 'project_id', p_project_id,
    'email', v_email, 'role', v_role, 'status', 'pending',
    'expires_at', v_expires_at, 'invitation_token', v_token
  );
exception
  when unique_violation then
    raise exception 'A pending invitation already exists for this email' using errcode = '23505';
end;
$$;

-- The raw invitation token must never be returned through the public Data API.
-- Only the trusted Edge Function's service-role client can execute this RPC.
revoke all on function public.create_project_invitation(uuid, text, text, uuid) from public, anon, authenticated;
grant execute on function public.create_project_invitation(uuid, text, text, uuid) to service_role;

-- Revoke an invitation when email delivery fails. The original inviter or a project
-- owner/admin can revoke a pending invitation; clients cannot update invitation rows.
create or replace function public.revoke_project_invitation(p_invitation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_invitation public.project_invitations%rowtype;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  select invitation.*
    into v_invitation
    from public.project_invitations invitation
   where invitation.id = p_invitation_id
   for update;

  if not found or v_invitation.status <> 'pending' then
    raise exception 'Pending invitation not found' using errcode = 'P0002';
  end if;

  if v_invitation.invited_by <> v_user_id
     and not private.has_project_role(v_invitation.project_id, array['owner','admin']) then
    raise exception 'Not allowed to revoke this invitation' using errcode = '42501';
  end if;

  update public.project_invitations
     set status = 'revoked'
   where id = v_invitation.id;

  return jsonb_build_object('invitation_id', v_invitation.id, 'status', 'revoked');
end;
$$;

revoke all on function public.revoke_project_invitation(uuid) from public, anon;
grant execute on function public.revoke_project_invitation(uuid) to authenticated;



create or replace function private.next_project_number(
  p_project_id uuid,
  p_counter_table text
) returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_next bigint;
begin
  if p_counter_table = 'task' then
    insert into public.project_task_counters(project_id)
    values (p_project_id)
    on conflict (project_id) do nothing;

    update public.project_task_counters
      set last_number = last_number + 1
      where project_id = p_project_id
      returning last_number into v_next;
  elsif p_counter_table = 'epic' then
    insert into public.project_epic_counters(project_id)
    values (p_project_id)
    on conflict (project_id) do nothing;

    update public.project_epic_counters
      set last_number = last_number + 1
      where project_id = p_project_id
      returning last_number into v_next;
  else
    raise exception 'Unsupported counter type';
  end if;

  return v_next;
end;
$$;

revoke all on function private.next_project_number(uuid, text) from public, anon, authenticated;

create or replace function public.set_project_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.project_members(project_id, user_id, role)
  values (new.id, new.created_by, 'owner');
  return new;
end;
$$;

revoke all on function public.set_project_owner() from public, anon, authenticated;

create trigger projects_add_owner
after insert on public.projects
for each row execute function public.set_project_owner();

create or replace function public.assign_task_number()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.task_number is null or new.task_number = 0 then
    new.task_number := private.next_project_number(new.project_id, 'task');
  end if;
  return new;
end;
$$;

create or replace function public.assign_epic_number()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.epic_number is null or new.epic_number = 0 then
    new.epic_number := private.next_project_number(new.project_id, 'epic');
  end if;
  return new;
end;
$$;

revoke all on function public.assign_task_number() from public, anon, authenticated;
revoke all on function public.assign_epic_number() from public, anon, authenticated;

create trigger tasks_assign_number
before insert on public.tasks
for each row execute function public.assign_task_number();

create trigger epics_assign_number
before insert on public.epics
for each row execute function public.assign_epic_number();

-- Updated-at maintenance.
create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function private.set_updated_at() from public, anon, authenticated;

create trigger projects_set_updated_at before update on public.projects
for each row execute function private.set_updated_at();
create trigger tasks_set_updated_at before update on public.tasks
for each row execute function private.set_updated_at();
create trigger epics_set_updated_at before update on public.epics
for each row execute function private.set_updated_at();

-- Enable RLS on every exposed application table.
alter table public.projects enable row level security;
alter table public.project_members enable row level security;
alter table public.project_invitations enable row level security;
alter table public.epics enable row level security;
alter table public.tasks enable row level security;
alter table public.project_task_counters enable row level security;
alter table public.project_epic_counters enable row level security;

-- Projects: all project members can read; admins/owners update; only owner deletes.
create policy projects_select on public.projects for select to authenticated
using (private.has_project_role(id, array['owner','admin','member','viewer']));
create policy projects_insert on public.projects for insert to authenticated
with check (created_by = (select auth.uid()));
create policy projects_update on public.projects for update to authenticated
using (private.has_project_role(id, array['owner','admin']))
with check (private.has_project_role(id, array['owner','admin']));
create policy projects_delete on public.projects for delete to authenticated
using (private.has_project_role(id, array['owner']));

-- Membership: project members can inspect membership; owner/admin can invite/remove;
-- only owner can change roles. Separate policies constrain each operation.
create policy project_members_select on public.project_members for select to authenticated
using (private.has_project_role(project_id, array['owner','admin','member','viewer']));
create policy project_members_insert on public.project_members for insert to authenticated
with check (
  private.has_project_role(project_id, array['owner','admin'])
  and role in ('admin','member','viewer')
);
create policy project_members_update on public.project_members for update to authenticated
using (private.has_project_role(project_id, array['owner']))
with check (private.has_project_role(project_id, array['owner']));
create policy project_members_delete on public.project_members for delete to authenticated
using (private.has_project_role(project_id, array['owner','admin']));

-- Invitations are visible/manageable only by project owners/admins.
create policy project_invitations_select on public.project_invitations for select to authenticated
using (private.has_project_role(project_id, array['owner','admin']));
-- Invitation state transitions are performed only by trusted database functions.
-- There is intentionally no direct UPDATE policy for authenticated clients.
create policy project_invitations_delete on public.project_invitations for delete to authenticated
using (private.has_project_role(project_id, array['owner','admin']));

-- Tasks and epics: members can create/update; owner/admin can delete; viewers read only.
create policy epics_select on public.epics for select to authenticated
using (private.has_project_role(project_id, array['owner','admin','member','viewer']));
create policy epics_insert on public.epics for insert to authenticated
with check (
  created_by = (select auth.uid())
  and private.has_project_role(project_id, array['owner','admin','member'])
);
create policy epics_update on public.epics for update to authenticated
using (private.has_project_role(project_id, array['owner','admin','member']))
with check (private.has_project_role(project_id, array['owner','admin','member']));
create policy epics_delete on public.epics for delete to authenticated
using (private.has_project_role(project_id, array['owner','admin']));

create policy tasks_select on public.tasks for select to authenticated
using (private.has_project_role(project_id, array['owner','admin','member','viewer']));
create policy tasks_insert on public.tasks for insert to authenticated
with check (
  created_by = (select auth.uid())
  and private.has_project_role(project_id, array['owner','admin','member'])
);
create policy tasks_update on public.tasks for update to authenticated
using (private.has_project_role(project_id, array['owner','admin','member']))
with check (private.has_project_role(project_id, array['owner','admin','member']));
create policy tasks_delete on public.tasks for delete to authenticated
using (private.has_project_role(project_id, array['owner','admin']));

-- Counter tables are internal to trigger functions and not directly exposed.
revoke all on public.project_task_counters, public.project_epic_counters from anon, authenticated;
grant all on public.project_task_counters, public.project_epic_counters to postgres, service_role;

-- RPC: projects the authenticated user belongs to.
create or replace function public.get_projects()
returns table (
  id uuid,
  name text,
  description text,
  created_by uuid,
  created_at timestamptz,
  updated_at timestamptz,
  role text
)
language sql
stable
security invoker
set search_path = ''
as $$
  select
    p.id,
    p.name,
    p.description,
    p.created_by,
    p.created_at,
    p.updated_at,
    pm.role
  from public.projects p
  inner join public.project_members pm
    on pm.project_id = p.id
  where pm.user_id = (select auth.uid())
  order by p.updated_at desc, p.created_at desc;
$$;

-- RPC: calendar daily counts and summary metrics for the current assignee.
create or replace function public.get_tasks_calendar_stats(
  p_start_date date,
  p_end_date date,
  p_project_id uuid default null,
  p_status public.task_status default null
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_result jsonb;
  v_today_utc date := (now() at time zone 'UTC')::date;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if p_start_date is null or p_end_date is null then
    raise exception 'Start date and end date are required' using errcode = '22004';
  end if;
  if p_end_date < p_start_date then
    raise exception 'End date must be on or after start date' using errcode = '22007';
  end if;
  if p_end_date - p_start_date > 366 then
    raise exception 'Date range cannot exceed 367 calendar days' using errcode = '22023';
  end if;

  with days as (
    select generate_series(p_start_date, p_end_date, interval '1 day')::date as day
  ),
  filtered as (
    select t.id, t.status, (t.due_date at time zone 'UTC')::date as due_day
    from public.tasks t
    where t.assignee_id = (select auth.uid())
      and t.due_date is not null
      and (t.due_date at time zone 'UTC') >= p_start_date::timestamp
      and (t.due_date at time zone 'UTC') < (p_end_date + 1)::timestamp
      and (p_project_id is null or t.project_id = p_project_id)
      and (p_status is null or t.status = p_status)
  ),
  daily_counts as (
    select f.due_day,
      count(*) filter (where f.status = 'TO_DO') as to_do,
      count(*) filter (where f.status = 'IN_PROGRESS') as in_progress,
      count(*) filter (where f.status = 'BLOCKED') as blocked,
      count(*) filter (where f.status = 'IN_REVIEW') as in_review,
      count(*) filter (where f.status = 'READY_FOR_QA') as ready_for_qa,
      count(*) filter (where f.status = 'REOPENED') as reopened,
      count(*) filter (where f.status = 'READY_FOR_PRODUCTION') as ready_for_production,
      count(*) filter (where f.status = 'DONE') as done
    from filtered f
    group by f.due_day
  ),
  totals as (
    select
      count(*) filter (where status = 'TO_DO') as to_do,
      count(*) filter (where status = 'IN_PROGRESS') as in_progress,
      count(*) filter (where status = 'BLOCKED') as blocked,
      count(*) filter (where status = 'IN_REVIEW') as in_review,
      count(*) filter (where status = 'READY_FOR_QA') as ready_for_qa,
      count(*) filter (where status = 'REOPENED') as reopened,
      count(*) filter (where status = 'READY_FOR_PRODUCTION') as ready_for_production,
      count(*) filter (where status = 'DONE') as done,
      count(*) as total_tasks,
      count(*) filter (where status = 'DONE') as done_tasks
    from filtered
  ),
  overdue as (
    select count(*) as overdue_tasks
    from public.tasks t
    where t.assignee_id = (select auth.uid())
      and t.due_date is not null
      and (t.due_date at time zone 'UTC')::date < v_today_utc
      and t.status <> 'DONE'
      and (p_project_id is null or t.project_id = p_project_id)
      and (p_status is null or t.status = p_status)
  )
  select jsonb_build_object(
    'daily', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'date', d.day,
          'TO_DO', coalesce(dc.to_do, 0),
          'IN_PROGRESS', coalesce(dc.in_progress, 0),
          'BLOCKED', coalesce(dc.blocked, 0),
          'IN_REVIEW', coalesce(dc.in_review, 0),
          'READY_FOR_QA', coalesce(dc.ready_for_qa, 0),
          'REOPENED', coalesce(dc.reopened, 0),
          'READY_FOR_PRODUCTION', coalesce(dc.ready_for_production, 0),
          'DONE', coalesce(dc.done, 0)
        ) order by d.day
      )
      from days d left join daily_counts dc on dc.due_day = d.day
    ), '[]'::jsonb),
    'totals', jsonb_build_object(
      'TO_DO', totals.to_do,
      'IN_PROGRESS', totals.in_progress,
      'BLOCKED', totals.blocked,
      'IN_REVIEW', totals.in_review,
      'READY_FOR_QA', totals.ready_for_qa,
      'REOPENED', totals.reopened,
      'READY_FOR_PRODUCTION', totals.ready_for_production,
      'DONE', totals.done
    ),
    'total_tasks', totals.total_tasks,
    'done_tasks', totals.done_tasks,
    'overdue_tasks', overdue.overdue_tasks
  )
  into v_result
  from totals cross join overdue;

  return v_result;
end;
$$;

-- RPC: assigned-task count grouped by project, including projects with zero matching tasks
-- only when the caller is a project member.
create or replace function public.get_tasks_count_per_project(
  p_start_date date,
  p_end_date date,
  p_status public.task_status default null
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if p_start_date is null or p_end_date is null then
    raise exception 'Start date and end date are required' using errcode = '22004';
  end if;
  if p_end_date < p_start_date then
    raise exception 'End date must be on or after start date' using errcode = '22007';
  end if;
  if p_end_date - p_start_date > 366 then
    raise exception 'Date range cannot exceed 367 calendar days' using errcode = '22023';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'project_id', p.id,
        'project_name', p.name,
        'tasks_count', coalesce(task_counts.tasks_count, 0)
      ) order by p.name, p.id
    ),
    '[]'::jsonb
  )
  into v_result
  from public.projects p
  join public.project_members pm
    on pm.project_id = p.id
   and pm.user_id = (select auth.uid())
  left join lateral (
    select count(*) as tasks_count
    from public.tasks t
    where t.project_id = p.id
      and t.assignee_id = (select auth.uid())
      and t.due_date is not null
      and (t.due_date at time zone 'UTC') >= p_start_date::timestamp
      and (t.due_date at time zone 'UTC') < (p_end_date + 1)::timestamp
      and (p_status is null or t.status = p_status)
  ) task_counts on true;

  return v_result;
end;
$$;



-- Accept an invitation only when the authenticated account email matches the
-- invitation email. The raw token is never stored; only its SHA-256 hash is stored.
create or replace function public.accept_project_invitation(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_user_email text;
  v_email_confirmed_at timestamptz;
  v_invitation public.project_invitations%rowtype;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  if p_token is null or length(p_token) < 32 or length(p_token) > 512 then
    raise exception 'Invalid or expired invitation' using errcode = '22023';
  end if;

  select lower(u.email), u.email_confirmed_at
    into v_user_email, v_email_confirmed_at
    from auth.users u
    where u.id = v_user_id;

  if v_user_email is null or v_email_confirmed_at is null then
    raise exception 'A verified email address is required to accept an invitation' using errcode = '28000';
  end if;

  select invitation.*
    into v_invitation
    from public.project_invitations invitation
    where invitation.token_hash = encode(extensions.digest(convert_to(p_token, 'UTF8'), 'sha256'), 'hex')
    for update;

  if not found
     or v_invitation.status <> 'pending'
     or v_invitation.expires_at <= now()
     or lower(v_invitation.email) <> v_user_email then
    raise exception 'Invalid or expired invitation' using errcode = '22023';
  end if;

  if exists (
    select 1 from public.project_members pm
    where pm.project_id = v_invitation.project_id
      and pm.user_id = v_user_id
  ) then
    raise exception 'You are already a member of this project' using errcode = '23505';
  end if;

  insert into public.project_members(project_id, user_id, role)
  values (v_invitation.project_id, v_user_id, v_invitation.role);

  update public.project_invitations
    set status = 'accepted', accepted_at = now()
    where id = v_invitation.id;

  return jsonb_build_object(
    'project_id', v_invitation.project_id,
    'role', v_invitation.role,
    'status', 'accepted'
  );
end;
$$;

revoke all on function public.accept_project_invitation(text) from public, anon;
grant execute on function public.accept_project_invitation(text) to authenticated;

revoke all on function public.get_tasks_calendar_stats(date, date, uuid, public.task_status) from public, anon;
revoke all on function public.get_tasks_count_per_project(date, date, public.task_status) from public, anon;
grant execute on function public.get_tasks_calendar_stats(date, date, uuid, public.task_status) to authenticated;
grant execute on function public.get_tasks_count_per_project(date, date, public.task_status) to authenticated;

revoke all on function public.get_projects() from public, anon;
grant execute on function public.get_projects() to authenticated;

-- The profiles table is intentionally absent. User identity remains in Supabase Auth.
-- No anon access is granted to application data.
revoke all on all tables in schema public from anon;
grant usage on schema public to authenticated;
grant select, insert, update, delete on
  public.projects, public.project_members,
  public.epics, public.tasks
to authenticated;
grant select, delete on public.project_invitations to authenticated;

commit;
