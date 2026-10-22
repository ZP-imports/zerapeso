-- 23_revendedor_do_cliente.sql
-- Tornar um cliente revendedor pelo painel (aba Clientes e aba Revendedores).
--   1) colunas CPF e cidade na tabela de revendedores;
--   2) libera as colunas que só o cadastro feito pelo próprio revendedor (portal) preenche e que
--      impediriam a equipe de cadastrar (ex.: usuário de login). Só tira a obrigatoriedade; não apaga nada;
--   3) função criar_revendedor, que a equipe usa no painel.
-- A tabela revendedores já existe (criada no Supabase para o portal de revenda); este arquivo só a complementa.
-- Rode este arquivo uma vez no SQL Editor da Supabase.

alter table public.revendedores add column if not exists cpf text;
alter table public.revendedores add column if not exists cidade text;

do $$
declare c record;
begin
  for c in
    select column_name
      from information_schema.columns
     where table_schema = 'public' and table_name = 'revendedores'
       and is_nullable = 'NO' and column_default is null and is_identity = 'NO'
       and column_name not in ('id', 'nome', 'tipo', 'status')
  loop
    execute format('alter table public.revendedores alter column %I drop not null', c.column_name);
  end loop;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'revendedores'
                and column_name = 'id' and data_type = 'uuid' and column_default is null) then
    alter table public.revendedores alter column id set default gen_random_uuid();
  end if;
end $$;

create or replace function public.criar_revendedor(
  p_nome text,
  p_cpf text,
  p_email text,
  p_telefone text,
  p_cidade text,
  p_tipo text,
  p_desconto numeric,
  p_obs text
) returns text
language plpgsql security definer set search_path = public as $$
declare
  novo text;
  fone text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  mail text := nullif(lower(btrim(coalesce(p_email, ''))), '');
begin
  if not public.eh_gestao() then raise exception 'Sem permissão para cadastrar revendedores.'; end if;
  if coalesce(btrim(p_nome), '') = '' then raise exception 'Informe o nome do revendedor.'; end if;
  if p_tipo not in ('comprador', 'consignado') then raise exception 'Tipo de revendedor inválido.'; end if;

  select id::text into novo
    from public.revendedores
   where (length(fone) >= 8 and right(regexp_replace(coalesce(telefone, ''), '\D', '', 'g'), 8) = right(fone, 8))
      or (mail is not null and lower(btrim(coalesce(email, ''))) = mail)
   limit 1;
  if novo is not null then raise exception 'Este cliente já é revendedor.'; end if;

  insert into public.revendedores (nome, cpf, email, telefone, cidade, tipo, desconto_pct, obs, status, aprovado_em)
  values (
    btrim(p_nome),
    nullif(regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g'), ''),
    mail,
    nullif(fone, ''),
    nullif(btrim(coalesce(p_cidade, '')), ''),
    p_tipo,
    greatest(0, least(80, coalesce(p_desconto, 0))),
    nullif(btrim(coalesce(p_obs, '')), ''),
    'ativo',
    now()
  )
  returning id::text into novo;

  return novo;
end $$;

revoke all on function public.criar_revendedor(text, text, text, text, text, text, numeric, text) from public, anon;
grant execute on function public.criar_revendedor(text, text, text, text, text, text, numeric, text) to authenticated;
