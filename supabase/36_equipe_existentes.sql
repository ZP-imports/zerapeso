-- 36: usuários da equipe, parte 2.
-- Dar acesso a quem já tem cadastro (mesmo e-mail), ver todos os usuários, buscar e excluir.

drop function if exists public.equipe_criar_usuario(text, text, text, text);

-- cria o acesso; se o e-mail já existe, libera o acesso na conta que já existe (e define a senha informada)
create or replace function public.equipe_criar_usuario(p_nome text, p_email text, p_senha text, p_papel text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid;
  mail text := lower(btrim(coalesce(p_email, '')));
  nm text := btrim(coalesce(p_nome, ''));
  existe boolean := false;
begin
  if not public.eh_admin() then raise exception 'Só o administrador cria acessos.'; end if;
  if nm = '' then raise exception 'Informe o nome.'; end if;
  if mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail inválido.'; end if;
  if length(coalesce(p_senha, '')) < 6 then raise exception 'A senha precisa ter pelo menos 6 caracteres.'; end if;
  if p_papel not in ('admin', 'logistica', 'separador') then raise exception 'Perfil inválido.'; end if;

  select id into uid from auth.users where lower(email) = mail limit 1;
  if uid is not null then
    existe := true;
    update auth.users
       set encrypted_password = crypt(p_senha, gen_salt('bf')),
           email_confirmed_at = coalesce(email_confirmed_at, now()),
           updated_at = now()
     where id = uid;
    update public.perfis set papel = p_papel, nome = nm, ativo = true where id = uid;
    return jsonb_build_object('id', uid, 'existente', true);
  end if;

  uid := gen_random_uuid();
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
  return jsonb_build_object('id', uid, 'existente', false);
end $$;

-- toda a equipe (administrador, logística e separação)
create or replace function public.equipe_listar() returns table (
  id uuid, nome text, sobrenome text, email text, papel text, ativo boolean, criado_em timestamptz, ultimo_acesso timestamptz)
language sql security definer set search_path = public as $$
  select p.id, p.nome, p.sobrenome, p.email, p.papel, p.ativo, p.criado_em, u.last_sign_in_at
    from public.perfis p left join auth.users u on u.id = p.id
   where public.eh_admin() and p.papel in ('admin', 'logistica', 'separador')
   order by p.criado_em
$$;

-- procura qualquer pessoa já cadastrada (cliente ou equipe) por nome ou e-mail
create or replace function public.equipe_buscar(p_q text) returns table (
  id uuid, nome text, sobrenome text, email text, papel text, ativo boolean, criado_em timestamptz, ultimo_acesso timestamptz)
language sql security definer set search_path = public as $$
  select p.id, p.nome, p.sobrenome, p.email, p.papel, p.ativo, p.criado_em, u.last_sign_in_at
    from public.perfis p left join auth.users u on u.id = p.id
   where public.eh_admin() and length(btrim(coalesce(p_q, ''))) >= 2
     and (coalesce(p.nome, '') || ' ' || coalesce(p.sobrenome, '') || ' ' || coalesce(p.email, '')) ilike '%' || btrim(p_q) || '%'
   order by p.criado_em desc
   limit 30
$$;

-- exclui o acesso. Se a pessoa tem pedidos (também é cliente), só perde o acesso da equipe.
create or replace function public.equipe_excluir(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'Só o administrador exclui usuários.'; end if;
  if p_id = auth.uid() then raise exception 'Você não pode excluir o seu próprio acesso.'; end if;
  if not exists (select 1 from public.perfis where id = p_id and papel in ('admin', 'logistica', 'separador')) then
    raise exception 'Usuário da equipe não encontrado.';
  end if;
  if exists (select 1 from public.pedidos where usuario_id = p_id) then
    update public.perfis set papel = 'cliente', ativo = true where id = p_id;
    return 'rebaixado';
  end if;
  begin
    delete from auth.users where id = p_id;
    return 'excluido';
  exception when foreign_key_violation then
    update public.perfis set papel = 'cliente', ativo = true where id = p_id;
    return 'rebaixado';
  end;
end $$;

revoke all on function public.equipe_criar_usuario(text, text, text, text) from public, anon;
revoke all on function public.equipe_listar() from public, anon;
revoke all on function public.equipe_buscar(text) from public, anon;
revoke all on function public.equipe_excluir(uuid) from public, anon;
grant execute on function public.equipe_criar_usuario(text, text, text, text) to authenticated;
grant execute on function public.equipe_listar() to authenticated;
grant execute on function public.equipe_buscar(text) to authenticated;
grant execute on function public.equipe_excluir(uuid) to authenticated;
