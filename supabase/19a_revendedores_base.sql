-- 19a_revendedores_base.sql
-- Tabelas base do sistema de revendedores. Elas NÃO existiam neste projeto do Supabase:
-- o painel (aba Revendedores) e o portal (revenda.html) dependem delas.
-- Rode ESTE arquivo primeiro, depois 19, 23 e 24.
-- As colunas seguem exatamente o que o painel e o portal já usam.

create table if not exists public.revendedores (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  email text,
  telefone text,
  senha text,
  status text not null default 'pendente' check (status in ('pendente', 'ativo', 'bloqueado')),
  tipo text not null default 'comprador' check (tipo in ('comprador', 'consignado')),
  desconto_pct integer not null default 0 check (desconto_pct between 0 and 80),
  obs text,
  config jsonb not null default '{}'::jsonb,
  cpf text,
  cidade text,
  aprovado_em timestamptz,
  criado_em timestamptz not null default now()
);
create unique index if not exists revendedores_email_uq on public.revendedores (lower(btrim(email))) where email is not null;

create table if not exists public.pedidos_revendedor (
  id uuid primary key default gen_random_uuid(),
  revendedor_id uuid not null references public.revendedores(id) on delete cascade,
  revendedor_nome text,
  itens jsonb not null default '[]'::jsonb,
  subtotal numeric(10, 2),
  obs text,
  tipo_pagamento text,
  status text not null default 'novo' check (status in ('novo', 'confirmado', 'em_separacao', 'em_rota', 'entregue', 'cancelado')),
  criado_em timestamptz not null default now()
);
create index if not exists pedidos_revendedor_rev_idx on public.pedidos_revendedor (revendedor_id, criado_em desc);

create table if not exists public.consignado_movimentos (
  id uuid primary key default gen_random_uuid(),
  revendedor_id uuid not null references public.revendedores(id) on delete cascade,
  tipo text not null check (tipo in ('saida', 'venda', 'repasse', 'devolucao')),
  produto_id integer,
  produto_nome text,
  quantidade numeric,
  valor_unitario numeric(10, 2),
  valor_total numeric(10, 2),
  pedido_id uuid references public.pedidos_revendedor(id) on delete set null,
  criado_em timestamptz not null default now()
);
create index if not exists consignado_mov_rev_idx on public.consignado_movimentos (revendedor_id, criado_em desc);

create table if not exists public.avisos_revendedores (
  id uuid primary key default gen_random_uuid(),
  titulo text not null,
  mensagem text,
  tipo text not null default 'info',
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);

alter table public.revendedores enable row level security;
alter table public.pedidos_revendedor enable row level security;
alter table public.consignado_movimentos enable row level security;
alter table public.avisos_revendedores enable row level security;

-- Política permissiva temporária (o portal ainda não usa Supabase Auth).
-- Restringir cada revendedor aos próprios dados é uma etapa seguinte.
drop policy if exists "service_role_all" on public.revendedores;
drop policy if exists "service_role_all" on public.pedidos_revendedor;
drop policy if exists "service_role_all" on public.consignado_movimentos;
drop policy if exists "service_role_all" on public.avisos_revendedores;
create policy "service_role_all" on public.revendedores for all using (true) with check (true);
create policy "service_role_all" on public.pedidos_revendedor for all using (true) with check (true);
create policy "service_role_all" on public.consignado_movimentos for all using (true) with check (true);
create policy "service_role_all" on public.avisos_revendedores for all using (true) with check (true);
