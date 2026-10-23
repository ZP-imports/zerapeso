-- 19_revendedor_precos_clientes.sql
-- Portal do revendedor: preço exclusivo por revendedor, preço de venda do próprio revendedor,
-- clientes do revendedor (entrega direta pela matriz) e custo/venda no pedido.
-- Os preços são por VARIAÇÃO do produto (ex.: "Caixa fechada 5 ampolas" e "Ampola + diluente"),
-- do mesmo jeito que a loja: cada variação tem o seu valor.
-- Rode depois das tabelas de revenda (revendedores, pedidos_revendedor...) e do arquivo 07 (variações).

-- Preço exclusivo (custo do revendedor), montado à mão pelo painel.
-- Variação sem linha aqui usa o preço da loja com o desconto padrão do revendedor (desconto_pct).
create table if not exists public.revendedor_precos_var (
  revendedor_id uuid not null references public.revendedores(id) on delete cascade,
  variacao_id uuid not null references public.produto_variacoes(id) on delete cascade,
  preco numeric(10,2) not null check (preco >= 0),
  atualizado_em timestamptz not null default now(),
  primary key (revendedor_id, variacao_id)
);

-- Preço de venda que o próprio revendedor define no catálogo dele.
create table if not exists public.revendedor_venda_var (
  revendedor_id uuid not null references public.revendedores(id) on delete cascade,
  variacao_id uuid not null references public.produto_variacoes(id) on delete cascade,
  preco_venda numeric(10,2) not null check (preco_venda >= 0),
  atualizado_em timestamptz not null default now(),
  primary key (revendedor_id, variacao_id)
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

alter table public.revendedor_precos_var enable row level security;
alter table public.revendedor_venda_var enable row level security;
alter table public.revendedor_clientes enable row level security;

-- Mesma política permissiva temporária das demais tabelas de revenda
-- (o portal ainda não usa Supabase Auth). Restringir junto com as outras.
drop policy if exists "service_role_all" on public.revendedor_precos_var;
drop policy if exists "service_role_all" on public.revendedor_venda_var;
drop policy if exists "service_role_all" on public.revendedor_clientes;
create policy "service_role_all" on public.revendedor_precos_var for all using (true) with check (true);
create policy "service_role_all" on public.revendedor_venda_var for all using (true) with check (true);
create policy "service_role_all" on public.revendedor_clientes for all using (true) with check (true);
