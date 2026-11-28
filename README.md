![Cover](Cover.png)

# Tasks Management — Frontend Training Project

Welcome to the **Tasks Management** training project by Rafiq.

This repository simulates a real-world frontend development environment. You will work from a provided product design and task board, integrate with a real Supabase backend, and use API documentation and Postman to explore and test the available endpoints.

## Getting Started

1. **Explore the product design:** Review the [Figma design](https://www.figma.com/design/zAwYa5nDWE2YirHYPpNabw/Tasks-Management?node-id=0-1&t=L7Jf026Stu5qCTd2-1).
2. **Review the work:** Open the [Task Board](https://www.notion.so/ee8ac15769ca83b790a281e6aca5682a?v=fb4ac15769ca8211827708b963b3b7fc) to understand the features and assigned tasks.
3. **Set up your backend:** Follow the [Supabase setup guide and API documentation](tasks_api_docs.md). Each student should create and configure their own Supabase project using the Dashboard.
4. **Explore and test the APIs:** Import the [Postman collection](Tasks%20Management.postman_collection.json) and configure it using the instructions in the API documentation.

## Repository Resources

- **Database schema:** [schema.sql](schema.sql) — full fresh-project schema for Supabase. Apply it only to a new training project; it is not a data-preserving migration.
- **Invitation Edge Function:** [send-invite-email](supabase/functions/send-invite-email/index.ts) — source code to deploy through the Supabase Dashboard.
- **API and backend setup documentation:** [tasks_api_docs.md](tasks_api_docs.md) — Dashboard-only setup instructions, environment configuration, and API reference.
- **Postman collection:** [Tasks Management.postman_collection.json](Tasks%20Management.postman_collection.json) — requests for exploring and testing the APIs.

## Tools

You will need a frontend development environment, a Supabase account, and Postman. The backend setup guide explains how to configure Supabase through its Dashboard; **Supabase CLI, Docker, and a local Supabase stack are not required**.

## Contact

If you have questions or need assistance, feel free to reach out:

- **Email:** [mahmoud.taha.dev@gmail.com](mailto:mahmoud.taha.dev@gmail.com)
- **LinkedIn:** [Mahmoud Taha](https://www.linkedin.com/in/mahmoud-taha-dev/)
