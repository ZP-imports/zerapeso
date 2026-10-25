-- 31_precos_individuais_links_kits.sql
-- 1) Produtos e preços INDIVIDUAIS por revendedor (substitui o desconto em porcentagem; o antigo continua
--    funcionando para quem ainda não migrou).
-- 2) Descrição nas variações + kits KIT MAX, KIT PRO e KIT PROMAX nos produtos de tirzepatida.
-- 3) Comprovante de entrega visível para o revendedor (só dos pedidos dele).
-- 4) Item "Outros" (texto livre) nos pedidos de revendedor que vão para a logística.
-- 5) Links de pedidos gerenciados pelo painel.
-- Não apaga nem altera dados existentes. Rode uma vez no SQL Editor da Supabase.

/* ---------- 1) preços individuais ---------- */
create table if not exists public.revendedor_produtos (
  revendedor_id uuid not null references public.revendedores(id) on delete cascade,
  variacao_id uuid not null references public.produto_variacoes(id) on delete cascade,
  habilitado boolean not null default true,
  preco numeric(10, 2) check (preco is null or preco >= 0),
  atualizado_em timestamptz not null default now(),
  primary key (revendedor_id, variacao_id)
);
create index if not exists revendedor_produtos_rev_idx on public.revendedor_produtos (revendedor_id);
alter table public.revendedor_produtos enable row level security;
drop policy if exists "service_role_all" on public.revendedor_produtos;
-- mesma política permissiva temporária das demais tabelas de revenda (o portal ainda não usa Supabase Auth)
create policy "service_role_all" on public.revendedor_produtos for all using (true) with check (true);

-- os preços exclusivos que já existiam viram a base da nova tabela (os originais continuam intactos)
insert into public.revendedor_produtos (revendedor_id, variacao_id, habilitado, preco)
select revendedor_id, variacao_id, true, preco from public.revendedor_precos_var
on conflict (revendedor_id, variacao_id) do nothing;

/* ---------- 2) descrição das variações e kits de tirzepatida ---------- */
alter table public.produto_variacoes add column if not exists descricao text;

do $$
declare
  p record;
  k record;
  prox int;
begin
  for p in select id from public.produtos where nome ilike '%tirzep%' or nome ilike '%tirzek%' loop
    select coalesce(max(ordem), 0) into prox from public.produto_variacoes where produto_id = p.id;
    for k in select * from (values
        ('KIT MAX',    'Bolsa delivery.'),
        ('KIT PRO',    'KIT MAX + seringas + ímã.'),
        ('KIT PROMAX', 'KIT PRO + porta-ampola + bolsa térmica.')
      ) as t(nome, descricao) loop
      if not exists (select 1 from public.produto_variacoes where produto_id = p.id and upper(nome) = k.nome) then
        prox := prox + 1;
        insert into public.produto_variacoes (produto_id, nome, unidades, ativo, ordem, descricao)
        values (p.id, k.nome, 1, true, prox, k.descricao);
      else
        update public.produto_variacoes set descricao = k.descricao
         where produto_id = p.id and upper(nome) = k.nome and coalesce(descricao, '') = '';
      end if;
    end loop;
  end loop;
end $$;

-- a linha de tirzepatida passa a ser a primeira do catálogo (só mexe na ordem, não renomeia nem apaga)
update public.produtos set ordem = -100 + id where (nome ilike '%tirzep%' or nome ilike '%tirzek%') and (ordem is null or ordem > -100);

/* ---------- 3) comprovante de entrega para o revendedor ---------- */
create or replace function public.revendedor_foto_entrega(p_rev uuid, p_pedido uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pid bigint;
  f record;
begin
  select pedido_id into pid from public.pedidos_revendedor where id = p_pedido and revendedor_id = p_rev;
  if pid is null then return null; end if;
  select foto, criado_em into f from public.pedido_fotos where pedido_id = pid order by criado_em desc limit 1;
  if f.foto is null then return null; end if;
  return jsonb_build_object('foto', f.foto, 'criado_em', f.criado_em);
end $$;
revoke all on function public.revendedor_foto_entrega(uuid, uuid) from public;
grant execute on function public.revendedor_foto_entrega(uuid, uuid) to anon, authenticated;

/* ---------- 4) item "Outros" ao enviar o pedido do revendedor para a logística ---------- */
create or replace function public.enviar_pedido_revendedor(p_id uuid) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  pr public.pedidos_revendedor%rowtype;
  rv public.revendedores%rowtype;
  novo bigint;
  quem text;
  itens jsonb := '[]'::jsonb;
  it jsonb;
  ent jsonb;
  dest jsonb;
  ex jsonb;
  cart boolean;
  outros boolean;
begin
  if not public.eh_gestao() then raise exception 'Sem permissão.'; end if;
  select * into pr from public.pedidos_revendedor where id = p_id;
  if not found then raise exception 'Pedido do revendedor não encontrado.'; end if;
  if pr.pedido_id is not null then return pr.pedido_id; end if;
  if pr.status = 'cancelado' then raise exception 'Este pedido está cancelado.'; end if;
  select * into rv from public.revendedores where id = pr.revendedor_id;
  select coalesce(nome, 'Equipe') into quem from public.perfis where id = auth.uid();

  for it in select * from jsonb_array_elements(coalesce(pr.itens, '[]'::jsonb)) loop
    outros := coalesce((it->>'outros')::boolean, false);
    itens := itens || jsonb_build_array(jsonb_build_object(
      'id', coalesce(nullif(it->>'produto_id', '')::int, 0),
      'var', case when outros then null else it->>'id' end,
      'name', coalesce(it->>'nome', 'Produto'),
      'base', coalesce(it->>'nome', 'Produto'),
      'opt', '',
      'qty', coalesce((it->>'qty')::numeric, 1),
      'unit', coalesce((it->>'preco')::numeric, 0),
      'unidades', 1,
      'semPreco', outros));
  end loop;

  if pr.entrega is not null and coalesce(pr.entrega->>'nome', '') <> '' then
    dest := jsonb_build_object(
      'rua', coalesce(pr.entrega->>'endereco', ''), 'num', coalesce(pr.entrega->>'numero', ''),
      'comp', coalesce(pr.entrega->>'complemento', ''), 'bairro', coalesce(pr.entrega->>'bairro', ''),
      'cidade', coalesce(pr.entrega->>'cidade', ''), 'uf', coalesce(pr.entrega->>'uf', ''),
      'cep', coalesce(pr.entrega->>'cep', ''), 'ref', '');
    ent := jsonb_build_object('nome', pr.entrega->>'nome', 'fone', regexp_replace(coalesce(pr.entrega->>'telefone', ''), '\D', '', 'g'),
      'dest', dest, 'data', '', 'turno', '', 'obs', 'Entrega direta para o cliente do revendedor ' || coalesce(rv.nome, ''));
  else
    dest := jsonb_build_object('rua', '', 'num', '', 'comp', '', 'bairro', '', 'cidade', coalesce(rv.cidade, ''), 'uf', '', 'cep', '', 'ref', '');
    ent := jsonb_build_object('nome', coalesce(rv.nome, ''), 'fone', regexp_replace(coalesce(rv.telefone, ''), '\D', '', 'g'),
      'dest', dest, 'data', '', 'turno', '', 'obs', 'Pedido do revendedor ' || coalesce(rv.nome, ''));
  end if;

  cart := coalesce((rv.config->>'carteira')::boolean, false);
  ex := jsonb_build_object('revendedor', true, 'revendedor_id', pr.revendedor_id, 'revendedor_nome', coalesce(rv.nome, ''),
    'revendedor_fone', regexp_replace(coalesce(rv.telefone, ''), '\D', '', 'g'), 'ped_rev_id', pr.id, 'manual', true);
  if cart then
    ex := ex || jsonb_build_object('pag_prev', coalesce(pr.pag_prev, '[{"data":"","pago":false,"pago_em":null}]'::jsonb));
  end if;

  insert into public.pedidos (usuario_id, seq, status, itens, entrega, pagamento, extra)
  values (auth.uid(), 1, 'realizado', itens, ent,
    jsonb_build_object('modo', 'link', 'status', coalesce(nullif(pr.pag_status, ''), 'pendente'), 'taxaEntrega', 0,
      'preferencia', coalesce(pr.forma_pagamento, '')),
    ex)
  returning id into novo;

  update public.pedidos_revendedor set pedido_id = novo where id = pr.id;

  begin
    perform public.alterar_status_pedido(novo, 'confirmado', null);
  exception when others then
    null;
  end;

  insert into public.pedido_eventos (pedido_id, tipo, publico, texto, por)
  values (novo, 'status', false, 'Pedido do revendedor ' || coalesce(rv.nome, '') || ' enviado para a logística.', coalesce(quem, 'Equipe'));

  return novo;
end $$;
revoke all on function public.enviar_pedido_revendedor(uuid) from public, anon;
grant execute on function public.enviar_pedido_revendedor(uuid) to authenticated;

/* ---------- 5) links de pedidos gerenciados pelo painel ---------- */
create table if not exists public.links_pedido (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  nome text not null,
  revendedor_id uuid references public.revendedores(id) on delete cascade,
  ativo boolean not null default true,
  mensagem text,
  campos jsonb not null default '{"nome":true,"telefone":true,"email":false,"cep":true,"endereco":true,"numero":true,"complemento":true,"bairro":true,"cidade":true,"obs":true}'::jsonb,
  produtos jsonb not null default '[]'::jsonb,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
alter table public.links_pedido enable row level security;
drop policy if exists links_pedido_ler on public.links_pedido;
create policy links_pedido_ler on public.links_pedido for select using (ativo);
drop policy if exists links_pedido_gestao on public.links_pedido;
create policy links_pedido_gestao on public.links_pedido for all to authenticated
  using (public.eh_gestao()) with check (public.eh_gestao());

-- pedido feito pelo cliente final por um link: guarda o link de origem e quem preencheu
alter table public.pedidos_revendedor add column if not exists link_id uuid references public.links_pedido(id) on delete set null;
alter table public.pedidos_revendedor add column if not exists origem text;
