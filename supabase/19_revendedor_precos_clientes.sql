-- Portal do revendedor: tabela de preço exclusiva, preço de venda próprio,
-- clientes do revendedor (entrega direta da matriz) e custo/venda no pedido.
-- Rode depois das tabelas de revenda.html (revendedores, pedidos_revendedor...).

-- Tabela de preço exclusiva, montada manualmente pelo admin (custo do revendedor).
-- Produto sem linha aqui usa o desconto_pct padrão do revendedor.
create table if not exists public.revendedor_precos (
  revendedor_id uuid not null references public.revendedores(id) on delete cascade,
  produto_id int not null,
  preco numeric(10,2) not null check (preco >= 0),
  atualizado_em timestamptz not null default now(),
  primary key (revendedor_id, produto_id)
);

-- Preço de venda que o próprio revendedor define para o catálogo dele.
create table if not exists public.revendedor_venda (
  revendedor_id uuid not null references public.revendedores(id) on delete cascade,
  produto_id int not null,
  preco_venda numeric(10,2) not null check (preco_venda >= 0),
  atualizado_em timestamptz not null default now(),
  primary key (revendedor_id, produto_id)
);

-- Clientes do revendedor, para entrega direta da matriz.
create table if not exists public.revendedor_clientes (
  id uuid primary key default gen_random_uuid(),
  revendedor_id uuid not null references public.revendedores(id) on delete cascade,
  nome text not null,
  telefone text,
  cep text,
  endereco text,
  numero text,
  complemento text,
  bairro text,
  cidade text,
  obs text,
  criado_em timestamptz not null default now()
);
create index if not exists revendedor_clientes_rev_idx on public.revendedor_clientes (revendedor_id);

-- Pedido: cliente final da entrega e quanto o revendedor espera vender.
alter table public.pedidos_revendedor
  add column if not exists cliente_id uuid references public.revendedor_clientes(id) on delete set null,
  add column if not exists cliente_nome text,
  add column if not exists entrega jsonb,
  add column if not exists custo_total numeric(10,2),
  add column if not exists venda_total numeric(10,2);

alter table public.revendedor_precos enable row level security;
alter table public.revendedor_venda enable row level security;
alter table public.revendedor_clientes enable row level security;

-- Mesma política permissiva temporária das demais tabelas de revenda
-- (o portal ainda não usa Supabase Auth). Restringir junto com as outras.
drop policy if exists "service_role_all" on public.revendedor_precos;
drop policy if exists "service_role_all" on public.revendedor_venda;
drop policy if exists "service_role_all" on public.revendedor_clientes;
create policy "service_role_all" on public.revendedor_precos for all using (true) with check (true);
create policy "service_role_all" on public.revendedor_venda for all using (true) with check (true);
create policy "service_role_all" on public.revendedor_clientes for all using (true) with check (true);
