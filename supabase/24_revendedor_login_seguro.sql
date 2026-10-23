-- 24_revendedor_login_seguro.sql
-- Login do portal do revendedor com senha criptografada (bcrypt).
-- Antes, a senha ficava em texto puro na tabela revendedores e o portal comparava direto na tabela.
--   1) converte as senhas que já existem para hash (quem já tem conta continua entrando com a mesma senha);
--   2) funções usadas pelo portal: entrar, cadastrar e alterar senha;
--   3) função usada pelo painel para definir a senha de um revendedor.
-- Rode depois dos arquivos 19 e 23, uma vez, no SQL Editor da Supabase.

create extension if not exists pgcrypto with schema extensions;

update public.revendedores
   set senha = extensions.crypt(senha, extensions.gen_salt('bf'))
 where senha is not null and senha !~ '^\$2[aby]\$';

create or replace function public.revendedor_entrar(p_email text, p_senha text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r public.revendedores;
begin
  select * into r from public.revendedores
   where lower(btrim(email)) = lower(btrim(coalesce(p_email, ''))) limit 1;
  if not found or r.senha is null or r.senha !~ '^\$2[aby]\$' then return null; end if;
  if r.senha <> crypt(coalesce(p_senha, ''), r.senha) then return null; end if;
  return to_jsonb(r) - 'senha';
end $$;

create or replace function public.revendedor_cadastrar(p_nome text, p_email text, p_telefone text, p_senha text)
returns text
language plpgsql security definer set search_path = public, extensions as $$
begin
  if coalesce(btrim(p_nome), '') = '' or coalesce(btrim(p_email), '') = '' then raise exception 'Informe nome e e-mail.'; end if;
  if length(coalesce(p_senha, '')) < 6 then raise exception 'A senha deve ter ao menos 6 caracteres.'; end if;
  if exists (select 1 from public.revendedores where lower(btrim(email)) = lower(btrim(p_email))) then
    raise exception 'EMAIL_EXISTE';
  end if;
  insert into public.revendedores (nome, email, telefone, senha, status, tipo, config, criado_em)
  values (btrim(p_nome), lower(btrim(p_email)), nullif(btrim(coalesce(p_telefone, '')), ''),
          crypt(p_senha, gen_salt('bf')), 'pendente', 'comprador', '{}'::jsonb, now());
  return 'ok';
end $$;

create or replace function public.revendedor_alterar_senha(p_id uuid, p_atual text, p_nova text)
returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare atual text;
begin
  if length(coalesce(p_nova, '')) < 6 then raise exception 'A nova senha deve ter pelo menos 6 caracteres.'; end if;
  select senha into atual from public.revendedores where id = p_id;
  if atual is null or atual !~ '^\$2[aby]\$' or atual <> crypt(coalesce(p_atual, ''), atual) then return false; end if;
  update public.revendedores set senha = crypt(p_nova, gen_salt('bf')) where id = p_id;
  return true;
end $$;

create or replace function public.admin_definir_senha_revendedor(p_id uuid, p_senha text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.eh_gestao() then raise exception 'Sem permissão.'; end if;
  if length(coalesce(p_senha, '')) < 6 then raise exception 'A senha deve ter ao menos 6 caracteres.'; end if;
  update public.revendedores set senha = crypt(p_senha, gen_salt('bf')) where id = p_id;
end $$;

revoke all on function public.revendedor_entrar(text, text) from public;
revoke all on function public.revendedor_cadastrar(text, text, text, text) from public;
revoke all on function public.revendedor_alterar_senha(uuid, text, text) from public;
revoke all on function public.admin_definir_senha_revendedor(uuid, text) from public, anon;
grant execute on function public.revendedor_entrar(text, text) to anon, authenticated;
grant execute on function public.revendedor_cadastrar(text, text, text, text) to anon, authenticated;
grant execute on function public.revendedor_alterar_senha(uuid, text, text) to anon, authenticated;
grant execute on function public.admin_definir_senha_revendedor(uuid, text) to authenticated;
