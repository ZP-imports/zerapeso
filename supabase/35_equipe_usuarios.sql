-- 35: usuários da equipe. Só o administrador cria acesso, muda o perfil, ativa/desativa e troca a senha.
-- Cada pessoa passa a ter o próprio login; o nome dela aparece no histórico das ações.

create or replace function public.equipe_criar_usuario(p_nome text, p_email text, p_senha text, p_papel text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := gen_random_uuid();
  mail text := lower(btrim(coalesce(p_email, '')));
  nm text := btrim(coalesce(p_nome, ''));
begin
  if not public.eh_admin() then raise exception 'Só o administrador cria acessos.'; end if;
  if nm = '' then raise exception 'Informe o nome.'; end if;
  if mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail inválido.'; end if;
  if length(coalesce(p_senha, '')) < 6 then raise exception 'A senha precisa ter pelo menos 6 caracteres.'; end if;
  if p_papel not in ('admin', 'logistica', 'separador') then raise exception 'Perfil inválido.'; end if;
  if exists (select 1 from auth.users where lower(email) = mail) then raise exception 'Já existe um acesso com este e-mail.'; end if;

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', mail,
          crypt(p_senha, gen_salt('bf')), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('nome', nm),
          now(), now(), '', '', '', '');

  begin
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), uid, uid::text,
            jsonb_build_object('sub', uid::text, 'email', mail, 'email_verified', true), 'email', now(), now(), now());
  exception when undefined_column then
    insert into auth.identities (id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (uid::text, uid, jsonb_build_object('sub', uid::text, 'email', mail), 'email', now(), now(), now());
  end;

  update public.perfis set papel = p_papel, nome = nm, ativo = true where id = uid;
  return uid;
end $$;

create or replace function public.equipe_definir(p_id uuid, p_papel text, p_ativo boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'Só o administrador altera usuários.'; end if;
  if p_id = auth.uid() then raise exception 'Você não pode alterar o seu próprio acesso por aqui.'; end if;
  if p_papel not in ('admin', 'logistica', 'separador') then raise exception 'Perfil inválido.'; end if;
  update public.perfis set papel = p_papel, ativo = coalesce(p_ativo, true) where id = p_id;
end $$;

create or replace function public.equipe_definir_senha(p_id uuid, p_senha text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.eh_admin() then raise exception 'Só o administrador troca senhas.'; end if;
  if length(coalesce(p_senha, '')) < 6 then raise exception 'A senha precisa ter pelo menos 6 caracteres.'; end if;
  if not exists (select 1 from public.perfis where id = p_id and papel in ('admin', 'logistica', 'separador')) then
    raise exception 'Usuário da equipe não encontrado.';
  end if;
  update auth.users set encrypted_password = crypt(p_senha, gen_salt('bf')), updated_at = now() where id = p_id;
end $$;

revoke all on function public.equipe_criar_usuario(text, text, text, text) from public, anon;
revoke all on function public.equipe_definir(uuid, text, boolean) from public, anon;
revoke all on function public.equipe_definir_senha(uuid, text) from public, anon;
grant execute on function public.equipe_criar_usuario(text, text, text, text) to authenticated;
grant execute on function public.equipe_definir(uuid, text, boolean) to authenticated;
grant execute on function public.equipe_definir_senha(uuid, text) to authenticated;
