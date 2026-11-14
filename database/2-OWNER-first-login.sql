-- CREATE THE OWNER LOGIN for a new school. Run ONCE, after SETUP-NEW-SCHOOL-all-in-one.sql.
-- Change ONLY the password between the quotes (8+ characters, letters and numbers). Username will be: owner
do $$
declare uid uuid := gen_random_uuid(); pw text := 'CHANGE-THIS-PASSWORD'; em text := 'owner@names.school';
begin
  if pw = 'CHANGE-THIS-PASSWORD' or length(pw) < 8 then raise exception 'First change the password written between the quotes, then run again'; end if;
  if exists (select 1 from profiles where username = 'owner') then raise exception 'An owner already exists'; end if;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
  values ('00000000-0000-0000-0000-000000000000',uid,'authenticated','authenticated',em,extensions.crypt(pw,extensions.gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now(),'','','','');
  insert into auth.identities(id,user_id,provider_id,identity_data,provider,last_sign_in_at,created_at,updated_at)
  values (gen_random_uuid(),uid,uid::text,jsonb_build_object('sub',uid::text,'email',em,'email_verified',true),'email',now(),now(),now());
  insert into profiles(id,username,name,role,must_change) values (uid,'owner','School Owner','admin',false);
end $$;
select username, name, role from profiles;
