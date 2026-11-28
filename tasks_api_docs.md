# Tasks Management API Documentation

> **Base URL:** `{{base_url}}`  
> **Version:** v1  
> **Date:** November 2026

---

## Environment Variables

| Variable | Description |
|---|---|
| `{{base_url}}` | The Supabase project base URL |
| `{{api_key}}` | The Supabase Publishable key (or legacy anon public key) |
| `{{access_token}}` | JWT access token — set automatically after Login |
| `{{refresh_token}}` | Refresh token — set automatically after Login |
| `{{user_id}}` | Authenticated user UUID — set automatically after Login |
| `{{frontend_origin}}` | Frontend origin used to build invitation links (e.g. `http://localhost:3000`); set manually in Postman |

---

## Student Setup (Supabase Dashboard Only)

Every Rafiq student creates and configures their **own Supabase project**. These steps use the Supabase Dashboard GUI; the Supabase CLI, terminal, Docker, and Supabase-specific local environment files are not required.

### 1. Create a Supabase project

1. Open the [Supabase Dashboard](https://supabase.com/dashboard).
2. Create a new project and wait for provisioning to finish.
3. Open the project.

### 2. Apply the database schema

1. In this repository, open `schema-redesign.sql` and copy its complete contents.
2. In the Supabase Dashboard, open **SQL Editor**.
3. Create a new query, paste the SQL, and run it.
4. Confirm that the query completes successfully before moving on.

Run the schema against a new, dedicated training project. It is a full schema setup script, not a small incremental migration. Do not run it against a project containing data you need to keep.

### 3. Create and deploy the invitation Edge Function

The invitation email workflow uses an Edge Function. Create it directly in the Dashboard:

1. Open **Edge Functions** in the project's left navigation.
2. Select **Deploy a new function**, then choose **Via Editor**.
3. Name the function exactly `send-invite-email`.
4. Open `supabase/functions/send-invite-email/index.ts` in this repository and copy the complete source.
5. Replace the editor's starter code with the copied source.
6. Select **Deploy function**.
7. Open the deployed function and use its **Test** panel to inspect the endpoint and test configuration.

The function validates the signed-in user's access token itself. Keep the function's JWT verification enabled when the Dashboard offers that setting.

### 4. Add email provider secrets

The function uses Gmail's fixed SMTP endpoint (`smtp.gmail.com:465`, implicit TLS), so students do not need to configure the host or port.

In **Edge Functions → Secrets**, add only the Gmail account credentials:

| Name | Value |
|---|---|
| `SMTP_USER` | Gmail address used to send invitations |
| `SMTP_PASSWORD` | Gmail App Password (not the normal Google account password) |
| `SMTP_FROM` | Optional sender address; defaults to `SMTP_USER` |

Create an App Password in the Google Account security settings after enabling 2-Step Verification. Never put the App Password in source code, frontend environment variables, or GitHub. Save the secrets. Supabase provides the project URL and API keys to the Edge Function runtime; students should not add Supabase's service-role/secret key to frontend code or commit any credentials. If a secret is changed, the function can read the updated value without a code redeployment.

### 5. Copy the project API details

1. In the Dashboard, open **Project Settings → API Keys** (or the project's **Connect** dialog).
2. Copy the **Project URL** and **Publishable key**.
3. Use them in the frontend app's own environment configuration and in the Postman collection's `base_url` and `api_key` variables. The publishable key is intended for client-side use; never use a secret/service-role key in the browser.

The frontend may have its own `.env.local` file for local app configuration. That file belongs to the frontend application, not to Supabase setup, and must not contain SMTP credentials or a Supabase secret/service-role key.

### 6. Configure and use Postman

1. Import `Tasks Management.postman_collection.json` into Postman.
2. Create/select a Postman environment and set `base_url` to the Supabase Project URL, `api_key` to the Publishable key, and `frontend_origin` to the frontend origin (for example, `http://localhost:3000`).
3. Sign up and log in using the collection. The login scripts save the access token, refresh token, and user ID to the selected Postman environment.
4. Set `project_id` to a project created by the signed-in user before testing project-specific requests.

No Supabase CLI, terminal commands, Docker setup, or Supabase local stack is part of the student setup.

---

## Table of Contents

- [Authentication](#authentication)
  - [Sign Up](#1-sign-up)
  - [Login](#2-login)
  - [Forgot Password](#3-forgot-password)
  - [Update Password](#4-update-password)
  - [Logout](#5-logout)
  - [Get User Data](#6-get-user-data)
  - [Generate New Token](#7-generate-new-token)
- [Projects](#projects)
  - [Create New Project](#8-create-new-project)
  - [Update Project](#9-update-project)
  - [Get Projects](#10-get-projects)
- [Epics](#epics)
  - [Create New Epic](#11-create-new-epic)
  - [Delete Epic](#12-delete-epic)
  - [Get Project Epics](#13-get-project-epics)
  - [Get Epic Details](#14-get-epic-details)
  - [Update Epic Details](#15-update-epic-details)
- [Members](#members)
  - [Get Project Members](#16-get-project-members)
  - [Invite New Member To Project](#17-invite-new-member-to-project)
  - [Accept Invitation](#18-accept-invitation)
- [Tasks](#tasks)
  - [Create New Task](#19-create-new-task)
  - [Delete Task](#20-delete-task)
  - [Update Task](#21-update-task)
  - [Get Project Tasks](#22-get-project-tasks)
  - [Get Epic Tasks](#23-get-epic-tasks)
  - [Get Tasks Calendar Stats](#24-get-tasks-calendar-stats)
  - [Get Tasks Count Per Project](#25-get-tasks-count-per-project)

---

## Authentication

---

### 1. Sign Up

Registers a new user account with email, password, and profile metadata.

**`POST`** `/auth/v1/signup`

#### Headers

| Header | Value | Description |
|---|---|---|
| `Content-Type` | `application/json` | Request body format |
| `apikey` | `{{api_key}}` | Supabase public API key |

#### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `email` | string | ✅ Yes | User's email address |
| `password` | string | ✅ Yes | Password (min 8 chars, uppercase, special char) |
| `data.name` | string | ✅ Yes | User's full name (stored in user metadata) |
| `data.department` | string | ✅ Yes | User's department (stored in user metadata) |

#### Body Example

```json
{
    "email": "test666@gmail.com",
    "password": "Password123!",
    "data": {
        "name": "Mahmoud Taha",
        "department": "Frontend"
    }
}
```

---

### 2. Login

Authenticates an existing user and returns access and refresh tokens. The test script auto-saves `access_token`, `refresh_token`, and `user_id` to environment variables.

**`POST`** `/auth/v1/token?grant_type=password`

#### Headers

| Header | Value | Description |
|---|---|---|
| `Content-Type` | `application/json` | Request body format |
| `apikey` | `{{api_key}}` | Supabase public API key |

#### Query Parameters

| Param | Value | Description |
|---|---|---|
| `grant_type` | `password` | OAuth grant type for password-based login |

#### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `email` | string | ✅ Yes | Registered user email |
| `password` | string | ✅ Yes | User password |

#### Body Example

```json
{
    "email": "user@example.com",
    "password": "@User1234"
}
```

---

### 3. Forgot Password

Sends a password recovery email to the given address.

**`POST`** `/auth/v1/recover`

#### Headers

| Header | Value | Description |
|---|---|---|
| `Content-Type` | `application/json` | Request body format |
| `apikey` | `{{api_key}}` | Supabase public API key |

#### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `email` | string | ✅ Yes | Email address linked to the account |

#### Body Example

```json
{
    "email": "user@example.com"
}
```

---

### 4. Update Password

Updates the authenticated user's password. Requires a valid Bearer token.

**`PUT`** `/auth/v1/user`

#### Headers

| Header | Value | Description |
|---|---|---|
| `Content-Type` | `application/json` | Request body format |
| `apikey` | `{{api_key}}` | Supabase public API key |
| `Authorization` | `Bearer <access_token>` | JWT access token of the authenticated user |

#### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `password` | string | ✅ Yes | The new password to set |

#### Body Example

```json
{
    "password": "NewPassword123!"
}
```

---

### 5. Logout

Invalidates the current session and access token, logging the user out.

**`POST`** `/auth/v1/logout`

#### Headers

| Header | Value | Description |
|---|---|---|
| `Content-Type` | `application/json` | Request body format |
| `apikey` | `{{api_key}}` | Supabase public API key |
| `Authorization` | `Bearer {{access_token}}` | JWT access token of the authenticated user |

---

### 6. Get User Data

Returns the profile and metadata of the currently authenticated user.

**`GET`** `/auth/v1/user`

#### Headers

| Header | Value | Description |
|---|---|---|
| `apikey` | `{{api_key}}` | Supabase public API key |
| `Authorization` | `Bearer {{access_token}}` | JWT access token of the authenticated user |
| `Content-Type` | `application/json` | Request body format |

---

### 7. Generate New Token

Uses a refresh token to issue a new access token. The test script auto-saves the updated tokens.

**`POST`** `/auth/v1/token?grant_type=refresh_token`

#### Headers

| Header | Value | Description |
|---|---|---|
| `Content-Type` | `application/json` | Request body format |
| `apikey` | `{{api_key}}` | Supabase public API key |

#### Query Parameters

| Param | Value | Description |
|---|---|---|
| `grant_type` | `refresh_token` | OAuth grant type for token refresh |

#### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `refresh_token` | string | ✅ Yes | The refresh token from a previous login or token refresh |

#### Body Example

```json
{
    "refresh_token": "{{refresh_token}}"
}
```

---

## Projects

---

### 8. Create New Project

Creates a new project for the authenticated user.

**`POST`** `/rest/v1/projects`

#### Headers

| Header | Value | Description |
|---|---|---|
| `apikey` | `{{api_key}}` | Supabase public API key |
| `Authorization` | `Bearer {{access_token}}` | JWT access token |
| `Content-Type` | `application/json` | Request body format |

#### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | ✅ Yes | Project name |
| `description` | string | ❌ No | Project description |

#### Body Example

```json
{
    "name": "Test new project",
    "description": "All design & implementation tasks"
}
```

---

### 9. Update Project

Updates an existing project's name and/or description by project ID.

**`PATCH`** `/rest/v1/projects?id=eq.{project_id}`

#### Headers

| Header | Value | Description |
|---|---|---|
| `apikey` | `{{api_key}}` | Supabase public API key |
| `Authorization` | `Bearer {{access_token}}` | JWT access token |
| `Content-Type` | `application/json` | Request body format |

#### Query Parameters

| Param | Value | Description |
|---|---|---|
| `id` | `eq.{project_id}` | PostgREST equality filter on project UUID |

#### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | ❌ No | New project name |
| `description` | string | ❌ No | New project description |

#### Body Example

```json
{
    "name": "Updated Project Name",
    "description": "Updated project description here."
}
```

---

### 10. Get Projects

Returns the projects where the authenticated user has a membership record (Owner, Admin, Member, or Viewer). The function derives the user ID from the access token using `auth.uid()`; the client must not send a `user_id`. Results are ordered by most recently updated project first.

**`GET`** `/rest/v1/rpc/get_projects`

#### Headers

| Header | Value | Description |
|---|---|---|
| `apikey` | `{{api_key}}` | Supabase public API key |
| `Authorization` | `Bearer {{access_token}}` | JWT access token |

No query parameters or request body are required.

#### Response Example

```json
[
  {
    "id": "298be621-59c7-4a62-ad2c-e640ff72135f",
    "name": "Taskly",
    "description": "Task management training project",
    "created_by": "d62a3f5e-92f8-4b1e-a8df-1bbbc3b2e9aa",
    "created_at": "2026-11-28T08:00:00+00:00",
    "updated_at": "2026-11-28T09:00:00+00:00",
    "role": "owner"
  }
]
```

The `role` field is the authenticated user's membership role in that project. An authenticated user with no project memberships receives an empty array. Unauthenticated requests are not granted function execution.

---

## Epics

---

### 11. Create New Epic

Creates a new epic within a project, with title, description, assignee, and deadline.

**`POST`** `/rest/v1/epics`

#### Headers

| Header | Value | Description |
|---|---|---|
| `apikey` | `{{api_key}}` | Supabase public API key |
| `Authorization` | `Bearer {{access_token}}` | JWT access token |
| `Content-Type` | `application/json` | Request body format |

#### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `title` | string | ✅ Yes | Epic title |
| `description` | string | ❌ No | Epic description |
| `assignee_id` | UUID | ❌ No | User ID of the assignee |
| `project_id` | UUID | ✅ Yes | Project this epic belongs to |
| `deadline` | date `YYYY-MM-DD` | ❌ No | Epic deadline |

#### Body Example

```json
{
    "title": "Epic Title",
    "description": "All design & implementation tasks",
    "assignee_id": "{{user_id}}",
    "project_id": "298be621-59c7-4a62-ad2c-e640ff72135f",
    "deadline": "2025-12-20"
}
```

---

### 12. Delete Epic

Permanently deletes an epic by its ID.

**`DELETE`** `/rest/v1/epics?id=eq.{epic_id}`

#### Headers

| Header | Value | Description |
|---|---|---|
| `apikey` | `{{api_key}}` | Supabase public API key |
| `Authorization` | `Bearer {{access_token}}` | JWT access token |
| `Content-Type` | `application/json` | Request body format |

#### Query Parameters

| Param | Value | Description |
|---|---|---|
| `id` | `eq.{epic_id}` | PostgREST equality filter on epic UUID |

---

### 13. Get Project Epics

Returns a paginated list of epics for a given project.

**`GET`** `/rest/v1/epics?project_id=eq.{project_id}&limit=20&offset=0`

#### Headers

| Header | Value | Description |
|---|---|---|
| `apikey` | `{{api_key}}` | Supabase public API key |
| `Authorization` | `Bearer {{access_token}}` | JWT access token |
| `Content-Type` | `application/json` | Request body format |
| `Prefer` | `count=exact` | Returns the total row count in the response header |

#### Query Parameters

| Param | Value | Description |
|---|---|---|
| `project_id` | `eq.{project_id}` | Filter epics by project UUID |
| `limit` | integer | Number of records to return (pagination) |
| `offset` | integer | Number of records to skip (pagination) |

---

### 14. Get Epic Details

Returns the full details of a single epic within a project.

**`GET`** `/rest/v1/epics?project_id=eq.{project_id}&id=eq.{epic_id}`

#### Headers

| Header | Value | Description |
|---|---|---|
| `apikey` | `{{api_key}}` | Supabase public API key |
| `Authorization` | `Bearer {{access_token}}` | JWT access token |
| `Content-Type` | `application/json` | Request body format |

#### Query Parameters

| Param | Value | Description |
|---|---|---|
| `project_id` | `eq.{project_id}` | Filter by project UUID |
| `id` | `eq.{epic_id}` | Filter by epic UUID |

---

### 15. Update Epic Details

Updates one or more fields of an existing epic.

**`PATCH`** `/rest/v1/epics?id=eq.{epic_id}`

#### Headers

| Header | Value | Description |
|---|---|---|
| `apikey` | `{{api_key}}` | Supabase public API key |
| `Authorization` | `Bearer {{access_token}}` | JWT access token |
| `Content-Type` | `application/json` | Request body format |

#### Query Parameters

| Param | Value | Description |
|---|---|---|
| `id` | `eq.{epic_id}` | PostgREST equality filter on epic UUID |

#### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `title` | string | ❌ No | Updated epic title |
| `description` | string | ❌ No | Updated epic description |
| `assignee_id` | UUID / null | ❌ No | Updated assignee (pass `null` to unassign) |
| `deadline` | date `YYYY-MM-DD` | ❌ No | Updated deadline |

#### Body Example

```json
{
    "title": "Updated epic title",
    "description": "Updated epic description",
    "assignee_id": null,
    "deadline": "2026-01-30"
}
```

---

## Members

---

### 16. Get Project Members

Returns all members belonging to a specific project.

**`GET`** `/rest/v1/project_members?project_id=eq.{project_id}`

#### Headers

| Header | Value | Description |
|
The endpoint reads from the `public.project_members` table. It returns membership records (including `user_id` and `role`); it does not return email or profile details because the redesigned schema does not expose a public `profiles` table.

---|---|---|
| `apikey` | `{{api_key}}` | Supabase public API key |
| `Authorization` | `Bearer {{access_token}}` | JWT access token |
| `Content-Type` | `application/json` | Request body format |

#### Query Parameters

| Param | Value | Description |
|---|---|---|
| `project_id` | `eq.{project_id}` | Filter members by project UUID |

---

### 17. Send Project Invitation

Creates an invitation and sends the invitation email through the Supabase Edge Function. The invitee does **not** need to have an existing Supabase Auth account. The Edge Function generates the invitation link using the request's `Origin` header, so it works with localhost and preview URLs during development. The browser supplies this header automatically; when testing with Postman, set it manually (for example, `http://localhost:3000`).

**`POST`** `/functions/v1/send-invite-email`

#### Headers

| Header | Value | Description |
|---|---|---|
| `apikey` | `{{api_key}}` | Supabase public API key |
| `Authorization` | `Bearer {{access_token}}` | JWT access token |
| `Origin` | `{{frontend_origin}}` | Frontend origin used to build the invitation URL; browsers send this automatically |
| `Content-Type` | `application/json` | Request body format |

#### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `project_id` | UUID | Yes | Project to invite the person to |
| `email` | string | Yes | Invitee email; an existing Auth account is not required |
| `role` | string | No | `admin`, `member`, or `viewer`; defaults to `member` |

#### Body Example

```json
{
  "project_id": "{{project_id}}",
  "email": "new.person@example.com",
  "role": "member"
}
```

#### Response Example

```json
{
  "success": true,
  "invitation": {
    "id": "00000000-0000-0000-0000-000000000000",
    "project_id": "00000000-0000-0000-0000-000000000000",
    "email": "new.person@example.com",
    "role": "member",
    "status": "pending",
    "expires_at": "2026-12-01T12:00:00Z"
  }
}
```

The Edge Function authenticates the caller using their JWT, then calls the token-returning `create_project_invitation` RPC using its server-only service-role key, constructs `{Origin}/accept-invitation?token=...`, and sends the email. The raw token is never returned to the frontend. The function allows any valid HTTP or HTTPS origin during development and requires an `Origin` header. CORS is configured with `Access-Control-Allow-Origin: *` for development.

Required Edge Function secrets: `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, and `SMTP_PASSWORD`; `SMTP_FROM` is optional and defaults to `SMTP_USER`. Supabase injects the project URL and API keys into the Edge Function runtime. The function uses its server-side service-role key only to call the token-returning `create_project_invitation` RPC. Never expose a service-role/secret key to the frontend.

The function requires an `Origin` header to construct the invitation URL. During this training project's development phase, it accepts any valid HTTP or HTTPS origin and uses that origin to create `/accept-invitation?token=...`. Browsers send `Origin` automatically; Postman must send it manually. CORS currently allows all origins for development. Before using this workflow in a production deployment, restrict accepted origins to the deployed frontend domains.

If email delivery fails after an invitation is created, the function attempts to revoke the undelivered invitation. Only project owners and admins can create invitations; only owners can invite someone as an admin. Existing project members and emails with an active pending invitation are rejected. Expired pending invitations are marked expired before a replacement is created.

#### Dashboard deployment and testing (GUI only)

If you have not deployed the function yet, follow **Student Setup → Create and deploy the invitation Edge Function** above. In short: open **Edge Functions → Deploy a new function → Via Editor**, create `send-invite-email`, paste the complete contents of `supabase/functions/send-invite-email/index.ts` from this repository, and select **Deploy function**.

Add the SMTP values under **Edge Functions → Secrets** as described in **Student Setup → Add email provider secrets**. No local Supabase stack, CLI, terminal command, or Supabase `.env` file is needed. The Dashboard's function editor can also be used to edit and redeploy the function later.

Use the **Test** panel on the deployed function or the **Send Project Invitation** request in the Postman collection to test it. For Postman, set `Origin: {{frontend_origin}}` (for example, `http://localhost:3000`) and use a valid signed-in user's access token.



---

### 18. Accept Project Invitation

Accepts an invitation using the one-time token. The caller must be authenticated with a verified email address matching the invitation email (case-insensitive). For invitees without an account, sign up using the invited email, verify it, then accept the invitation.

**`POST`** `/rest/v1/rpc/accept_project_invitation`

#### Headers

| Header | Value | Description |
|---|---|---|
| `apikey` | `{{api_key}}` | Supabase public API key |
| `Authorization` | `Bearer {{access_token}}` | JWT access token of the verified invitee |
| `Content-Type` | `application/json` | Request body format |

#### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `p_token` | string | Yes | Raw invitation token received in the invitation link |

#### Body Example

```json
{
  "p_token": "{{invitation_token}}"
}
```

#### Response Example

```json
{
  "project_id": "00000000-0000-0000-0000-000000000000",
  "role": "member",
  "status": "accepted"
}
```

The token is single-use and expires seven days after creation. Acceptance fails for unauthenticated users, unverified emails, email mismatches, invalid/expired/revoked tokens, or users who are already project members.


---

## Tasks

---

### 19. Create New Task

Creates a new task within a project and optionally links it to an epic.

**`POST`** `/rest/v1/tasks`

#### Headers

| Header | Value | Description |
|---|---|---|
| `apikey` | `{{api_key}}` | Supabase public API key |
| `Authorization` | `Bearer {{access_token}}` | JWT access token |
| `Content-Type` | `application/json` | Request body format |

#### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `project_id` | UUID | ✅ Yes | Project the task belongs to |
| `epic_id` | UUID | ❌ No | Epic the task is linked to |
| `title` | string | ✅ Yes | Task title |
| `description` | string | ❌ No | Task description |
| `assignee_id` | UUID | ❌ No | User ID of the assignee |
| `due_date` | ISO 8601 datetime | ❌ No | Task due date (e.g. `2026-02-10T12:00:00Z`) |
| `status` | enum | ❌ No | `TO_DO` \| `IN_PROGRESS` \| `DONE` |

#### Body Example

```json
{
    "project_id": "298be621-59c7-4a62-ad2c-e640ff72135f",
    "epic_id": "5360f7b4-5be0-4ca0-b0cc-31bff72434dd",
    "title": "Implement login validation",
    "description": "Add client-side and server-side validation",
    "assignee_id": "{{user_id}}",
    "due_date": "2026-02-10T12:00:00Z",
    "status": "TO_DO"
}
```

---

### 20. Delete Task

Permanently deletes a task by its ID.

**`DELETE`** `/rest/v1/tasks?id=eq.{task_id}`

#### Headers

| Header | Value | Description |
|---|---|---|
| `apikey` | `{{api_key}}` | Supabase public API key |
| `Authorization` | `Bearer {{access_token}}` | JWT access token |
| `Content-Type` | `application/json` | Request body format |

#### Query Parameters

| Param | Value | Description |
|---|---|---|
| `id` | `eq.{task_id}` | PostgREST equality filter on task UUID |

---

### 21. Update Task

Updates one or more fields of a task (e.g. status change).

**`PATCH`** `/rest/v1/tasks?id=eq.{task_id}`

#### Headers

| Header | Value | Description |
|---|---|---|
| `apikey` | `{{api_key}}` | Supabase public API key |
| `Authorization` | `Bearer {{access_token}}` | JWT access token |
| `Content-Type` | `application/json` | Request body format |

#### Query Parameters

| Param | Value | Description |
|---|---|---|
| `id` | `eq.{task_id}` | PostgREST equality filter on task UUID |

#### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `title` | string | ❌ No | Updated task title |
| `description` | string | ❌ No | Updated task description |
| `assignee_id` | UUID / null | ❌ No | Updated assignee (pass `null` to unassign) |
| `due_date` | ISO 8601 datetime | ❌ No | Updated due date |
| `status` | enum | ❌ No | `TO_DO` \| `IN_PROGRESS` \| `DONE` |

#### Body Example

```json
{
    "status": "IN_PROGRESS"
}
```

---

### 22. Get Project Tasks

Returns tasks for a project. Supports filtering by status, title search, task ID, and pagination.

**`GET`** `/rest/v1/tasks?project_id=eq.{project_id}`

#### Headers

| Header | Value | Description |
|---|---|---|
| `apikey` | `{{api_key}}` | Supabase public API key |
| `Authorization` | `Bearer {{access_token}}` | JWT access token |
| `Content-Type` | `application/json` | Request body format |
| `Prefer` | `count=exact` | Returns the total row count in the response header |

#### Query Parameters

| Param | Value | Description |
|---|---|---|
| `project_id` | `eq.{project_id}` | **Required** — filter by project UUID |
| `status` | `eq.TO_DO` *(optional)* | Filter by task status |
| `title` | `ilike.%{search}%` *(optional)* | Case-insensitive title search |
| `id` | `eq.{task_id}` *(optional)* | Filter by specific task UUID |
| `limit` | integer *(optional)* | Max records to return (pagination) |
| `offset` | integer *(optional)* | Records to skip (pagination) |

---

### 23. Get Epic Tasks

Returns all tasks linked to a specific epic.

**`GET`** `/rest/v1/tasks?epic_id=eq.{epic_id}`

#### Headers

| Header | Value | Description |
|---|---|---|
| `apikey` | `{{api_key}}` | Supabase public API key |
| `Authorization` | `Bearer {{access_token}}` | JWT access token |
| `Content-Type` | `application/json` | Request body format |

#### Query Parameters

| Param | Value | Description |
|---|---|---|
| `epic_id` | `eq.{epic_id}` | Filter tasks by epic UUID |

---

## Task Statistics

---

### 24. Get Tasks Calendar Stats

Returns daily task counts grouped by status for the authenticated user (tasks assigned to the caller), plus totals and overdue metrics. Date boundaries use UTC. Every date in the requested range is returned, including dates with zero tasks.

**`POST`** `/rest/v1/rpc/get_tasks_calendar_stats`

#### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `p_start_date` | date | Yes | Inclusive start date, `YYYY-MM-DD` |
| `p_end_date` | date | Yes | Inclusive end date; maximum range is 367 calendar days |
| `p_project_id` | UUID / null | No | Restrict results to one project |
| `p_status` | task status / null | No | Restrict results to one status |

#### Body Example

```json
{
  "p_start_date": "2026-11-01",
  "p_end_date": "2026-11-30",
  "p_project_id": null,
  "p_status": null
}
```

#### Response Shape

```json
{
  "daily": [
    {
      "date": "2026-11-01",
      "TO_DO": 2,
      "IN_PROGRESS": 1,
      "BLOCKED": 0,
      "IN_REVIEW": 0,
      "READY_FOR_QA": 0,
      "REOPENED": 0,
      "READY_FOR_PRODUCTION": 0,
      "DONE": 1
    }
  ],
  "totals": {
    "TO_DO": 2,
    "IN_PROGRESS": 1,
    "BLOCKED": 0,
    "IN_REVIEW": 0,
    "READY_FOR_QA": 0,
    "REOPENED": 0,
    "READY_FOR_PRODUCTION": 0,
    "DONE": 1
  },
  "total_tasks": 4,
  "done_tasks": 1,
  "overdue_tasks": 2
}
```

The optional status filter applies to daily counts, totals, and overdue counts. Overdue means a non-DONE task whose UTC due date is earlier than the current UTC date. Tasks without a due date are excluded.

---

### 25. Get Tasks Count Per Project

Returns one item per project the authenticated user belongs to, with the count of tasks assigned to the caller and due within the requested UTC date range. Projects with no matching tasks are returned with `tasks_count: 0`.

**`POST`** `/rest/v1/rpc/get_tasks_count_per_project`

#### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `p_start_date` | date | Yes | Inclusive start date, `YYYY-MM-DD` |
| `p_end_date` | date | Yes | Inclusive end date; maximum range is 367 calendar days |
| `p_status` | task status / null | No | Optional status filter |

#### Body Example

```json
{
  "p_start_date": "2026-11-01",
  "p_end_date": "2026-11-30",
  "p_status": null
}
```

#### Response Example

```json
[
  {
    "project_id": "00000000-0000-0000-0000-000000000000",
    "project_name": "Website Redesign",
    "tasks_count": 12
  },
  {
    "project_id": "11111111-1111-1111-1111-111111111111",
    "project_name": "Mobile App",
    "tasks_count": 0
  }
]
```

Both statistics RPCs require authentication. Invalid/missing dates, reversed ranges, and ranges exceeding 367 days are rejected.
