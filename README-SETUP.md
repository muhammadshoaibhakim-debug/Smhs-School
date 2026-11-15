# Scholars Model High School (SMHS Ellahabad, Kasur): Setup

Same software and design as before. Only the school name and logo are new.

## Step 1: Create the Supabase project (new account)
1. supabase.com > New project (any name, strong database password, region close to Pakistan).
2. Wait until it is ready.

## Step 2: Database (run in this order, once each)
1. SQL Editor > New query > paste ALL of `database/1-MASTER-DATABASE-all-patches.sql` > Run.
   At the end you get a check table: tables = tables_with_rls, exams_term_column = 1.
2. New query > open `database/2-OWNER-first-login.sql`, replace CHANGE-THIS-PASSWORD with YOUR OWN
   strong password (12+ characters, letters and numbers) > Run. You should see: owner | School Owner | admin.
3. Authentication > Sign In / Providers: turn OFF "Allow new users to sign up".

## Step 3: Keys (already filled in this version)
Supabase > Project Settings > API Keys. Open `public/config.js` and replace:
- PASTE-YOUR-PROJECT-URL-HERE with the project URL (https://xxxx.supabase.co)
- PASTE-YOUR-PUBLISHABLE-KEY-HERE with the PUBLISHABLE key (starts with sb_publishable_)
Never put a secret / service_role key anywhere.

## Step 4: GitHub
New PRIVATE repository. Upload everything inside this folder (public, database, optional-notifications,
wrangler.jsonc, README-SETUP.md): Add file > Upload files > Commit.

## Step 5: Cloudflare
Workers & Pages > Create > Import a repository > pick the repo.
- Project / worker name: smhsschool (must match "name" in wrangler.jsonc)
- Build command: empty
- Deploy command: npx wrangler deploy   (do NOT add --assets=site)
Then open the worker > Domains: turn ON the workers.dev toggle. Your link will be
https://smhsschool.<your-account>.workers.dev

## Step 6: First login
Username: owner, password: the one you chose in Step 2. Then Backup page > System check:
every line should say OK (the Notification clock line may say CHECK, that is fine).

## Updating later
Change files on GitHub > Cloudflare deploys by itself > press Ctrl + Shift + R.

## PTM tracker (patch 16)
Run `database/4-PATCH-16-PTM.sql` once in Supabase (SQL Editor) on the live project. New projects get it from the master file.
Then open "PTM" in the menu. Owner/manager see every class, a teacher sees only their own class.
