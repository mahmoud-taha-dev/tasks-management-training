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

create table public.comments (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  task_id uuid,
  epic_id uuid,
  author_id uuid not null default auth.uid() references auth.users(id) on delete restrict,
  content text not null check (length(btrim(content)) > 0),
  created_at timestamptz not null default now(),
  constraint comments_task_same_project_fkey foreign key (project_id, task_id)
    references public.tasks(project_id, id) on delete cascade,
  constraint comments_epic_same_project_fkey foreign key (project_id, epic_id)
    references public.epics(project_id, id) on delete cascade,
  constraint comments_exactly_one_parent check (
    (task_id is not null and epic_id is null) or
    (task_id is null and epic_id is not null)
  )
);

create table public.attachments (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  task_id uuid,
  epic_id uuid,
  uploaded_by uuid not null default auth.uid() references auth.users(id) on delete restrict,
  url text not null check (length(btrim(url)) > 0),
  file_name text,
  created_at timestamptz not null default now(),
  constraint attachments_task_same_project_fkey foreign key (project_id, task_id)
    references public.tasks(project_id, id) on delete cascade,
  constraint attachments_epic_same_project_fkey foreign key (project_id, epic_id)
    references public.epics(project_id, id) on delete cascade,
  constraint attachments_exactly_one_parent check (
    (task_id is not null and epic_id is null) or
    (task_id is null and epic_id is not null)
  )
);

create table public.departments (
  id bigint generated always as identity primary key,
  name text not null unique check (length(btrim(name)) > 0)
);

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
alter table public.comments enable row level security;
alter table public.attachments enable row level security;
alter table public.departments enable row level security;
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
create policy project_invitations_insert on public.project_invitations for insert to authenticated
with check (
  invited_by = (select auth.uid())
  and private.has_project_role(project_id, array['owner','admin'])
);
create policy project_invitations_update on public.project_invitations for update to authenticated
using (private.has_project_role(project_id, array['owner','admin']))
with check (private.has_project_role(project_id, array['owner','admin']));
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

-- Comments and attachments: project members can read; contributors can create;
-- only contributors can edit; owner/admin can delete any.
create policy comments_select on public.comments for select to authenticated
using (private.has_project_role(project_id, array['owner','admin','member','viewer']));
create policy comments_insert on public.comments for insert to authenticated
with check (
  author_id = (select auth.uid())
  and private.has_project_role(project_id, array['owner','admin','member'])
);
create policy comments_update on public.comments for update to authenticated
using (author_id = (select auth.uid()) and private.has_project_role(project_id, array['owner','admin','member']))
with check (author_id = (select auth.uid()) and private.has_project_role(project_id, array['owner','admin','member']));
create policy comments_delete on public.comments for delete to authenticated
using (
  private.has_project_role(project_id, array['owner','admin'])
  or (author_id = (select auth.uid()) and private.has_project_role(project_id, array['member']))
);

create policy attachments_select on public.attachments for select to authenticated
using (private.has_project_role(project_id, array['owner','admin','member','viewer']));
create policy attachments_insert on public.attachments for insert to authenticated
with check (
  uploaded_by = (select auth.uid())
  and private.has_project_role(project_id, array['owner','admin','member'])
);
create policy attachments_update on public.attachments for update to authenticated
using (uploaded_by = (select auth.uid()) and private.has_project_role(project_id, array['owner','admin','member']))
with check (uploaded_by = (select auth.uid()) and private.has_project_role(project_id, array['owner','admin','member']));
create policy attachments_delete on public.attachments for delete to authenticated
using (
  private.has_project_role(project_id, array['owner','admin'])
  or (uploaded_by = (select auth.uid()) and private.has_project_role(project_id, array['member']))
);

-- Departments are reference data: authenticated users may read; writes are service-side only.
create policy departments_select on public.departments for select to authenticated using (true);

-- Counter tables are internal to trigger functions and not directly exposed.
revoke all on public.project_task_counters, public.project_epic_counters from anon, authenticated;
grant all on public.project_task_counters, public.project_epic_counters to postgres, service_role;

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

revoke all on function public.get_tasks_calendar_stats(date, date, uuid, public.task_status) from public, anon;
revoke all on function public.get_tasks_count_per_project(date, date, public.task_status) from public, anon;
grant execute on function public.get_tasks_calendar_stats(date, date, uuid, public.task_status) to authenticated;
grant execute on function public.get_tasks_count_per_project(date, date, public.task_status) to authenticated;

-- The profiles table is intentionally absent. User identity remains in Supabase Auth.
-- No anon access is granted to application data.
revoke all on all tables in schema public from anon;
grant usage on schema public to authenticated;
grant select, insert, update, delete on
  public.projects, public.project_members, public.project_invitations,
  public.epics, public.tasks, public.comments, public.attachments
to authenticated;
grant select on public.departments to authenticated;

commit;
