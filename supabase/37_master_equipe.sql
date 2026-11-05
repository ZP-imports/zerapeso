-- 37: conta MASTER. Só o master vê e mexe na conta master. Os outros administradores veem e criam
-- os demais usuários, mas não enxergam nem alteram a conta master.

alter table public.perfis add column if not exists master boolean not null default false;

-- a conta administradora mais antiga vira a master (só se ainda não houver nenhuma)
update public.perfis set master = true
 where id = (select id from public.perfis where papel = 'admin' and ativo order by criado_em limit 1)
   and not exists (select 1 from public.perfis where master);

create or replace function public.eh_master() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select master and ativo from public.perfis where id = auth.uid()), false)
$$;
grant execute on function public.eh_master() to authenticated;

-- por qualquer caminho (inclusive a API direta), ninguém além do master altera a conta master
create or replace function public.proteger_master() returns trigger
language plpgsql security invoker set search_path = public as $$
begin
  if current_user in ('authenticated', 'anon') then
    if tg_op = 'DELETE' then
      if old.master and not public.eh_master() then raise exception 'Esta conta é protegida.'; end if;
      return old;
    end if;
    if old.master and auth.uid() is distinct from old.id and not public.eh_master() then
      raise exception 'Esta conta é protegida.';
    end if;
    if new.master is distinct from old.master and not public.eh_master() then
      raise exception 'Só o master altera esta marca.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists perfis_proteger_master on public.perfis;
create trigger perfis_proteger_master before update or delete on public.perfis
for each row execute function public.proteger_master();

drop function if exists public.equipe_listar();
drop function if exists public.equipe_buscar(text);

create or replace function public.equipe_listar() returns table (
  id uuid, nome text, sobrenome text, email text, papel text, ativo boolean, criado_em timestamptz, ultimo_acesso timestamptz, master boolean)
language sql security definer set search_path = public as $$
  select p.id, p.nome, p.sobrenome, p.email, p.papel, p.ativo, p.criado_em, u.last_sign_in_at, p.master
    from public.perfis p left join auth.users u on u.id = p.id
   where public.eh_admin() and p.papel in ('admin', 'logistica', 'separador')
     and (not p.master or public.eh_master())
   order by p.criado_em
$$;

create or replace function public.equipe_buscar(p_q text) returns table (
  id uuid, nome text, sobrenome text, email text, papel text, ativo boolean, criado_em timestamptz, ultimo_acesso timestamptz, master boolean)
language sql security definer set search_path = public as $$
  select p.id, p.nome, p.sobrenome, p.email, p.papel, p.ativo, p.criado_em, u.last_sign_in_at, p.master
    from public.perfis p left join auth.users u on u.id = p.id
   where public.eh_admin() and length(btrim(coalesce(p_q, ''))) >= 2
     and (not p.master or public.eh_master())
     and (coalesce(p.nome, '') || ' ' || coalesce(p.sobrenome, '') || ' ' || coalesce(p.email, '')) ilike '%' || btrim(p_q) || '%'
   order by p.criado_em desc
   limit 30
$$;

create or replace function public.equipe_definir(p_id uuid, p_papel text, p_ativo boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'Só o administrador altera usuários.'; end if;
  if p_id = auth.uid() then raise exception 'Você não pode alterar o seu próprio acesso por aqui.'; end if;
  if exists (select 1 from public.perfis where id = p_id and master) and not public.eh_master() then raise exception 'Esta conta é protegida.'; end if;
  if p_papel not in ('admin', 'logistica', 'separador') then raise exception 'Perfil inválido.'; end if;
  update public.perfis set papel = p_papel, ativo = coalesce(p_ativo, true) where id = p_id;
end $$;

create or replace function public.equipe_definir_senha(p_id uuid, p_senha text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.eh_admin() then raise exception 'Só o administrador troca senhas.'; end if;
  if length(coalesce(p_senha, '')) < 6 then raise exception 'A senha precisa ter pelo menos 6 caracteres.'; end if;
  if exists (select 1 from public.perfis where id = p_id and master) and not public.eh_master() then raise exception 'Esta conta é protegida.'; end if;
  if not exists (select 1 from public.perfis where id = p_id and papel in ('admin', 'logistica', 'separador')) then
    raise exception 'Usuário da equipe não encontrado.';
  end if;
  update auth.users set encrypted_password = crypt(p_senha, gen_salt('bf')), updated_at = now() where id = p_id;
end $$;

create or replace function public.equipe_excluir(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'Só o administrador exclui usuários.'; end if;
  if p_id = auth.uid() then raise exception 'Você não pode excluir o seu próprio acesso.'; end if;
  if exists (select 1 from public.perfis where id = p_id and master) then raise exception 'A conta master não pode ser excluída.'; end if;
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

-- criar acesso: se o e-mail já existe e é o master, só o master mexe
create or replace function public.equipe_criar_usuario(p_nome text, p_email text, p_senha text, p_papel text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid;
  mail text := lower(btrim(coalesce(p_email, '')));
  nm text := btrim(coalesce(p_nome, ''));
begin
  if not public.eh_admin() then raise exception 'Só o administrador cria acessos.'; end if;
  if nm = '' then raise exception 'Informe o nome.'; end if;
  if mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail inválido.'; end if;
  if length(coalesce(p_senha, '')) < 6 then raise exception 'A senha precisa ter pelo menos 6 caracteres.'; end if;
  if p_papel not in ('admin', 'logistica', 'separador') then raise exception 'Perfil inválido.'; end if;

  select id into uid from auth.users where lower(email) = mail limit 1;
  if uid is not null then
    if exists (select 1 from public.perfis where id = uid and master) and not public.eh_master() then raise exception 'Esta conta é protegida.'; end if;
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

revoke all on function public.equipe_listar() from public, anon;
revoke all on function public.equipe_buscar(text) from public, anon;
grant execute on function public.equipe_listar() to authenticated;
grant execute on function public.equipe_buscar(text) to authenticated;
