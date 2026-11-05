-- 42: preços por categoria de revendedor (A, B e C).
-- Cada linha é uma variação que a categoria vende, com o preço dela. Quem não tem linha não é vendido para essa categoria.

create table if not exists public.revenda_categoria_precos (
  categoria text not null check (categoria in ('A', 'B', 'C')),
  variacao_id uuid not null references public.produto_variacoes(id) on delete cascade,
  preco numeric(10,2) not null check (preco >= 0),
  atualizado_em timestamptz not null default now(),
  primary key (categoria, variacao_id)
);

alter table public.revenda_categoria_precos enable row level security;

-- o portal e o link de pedido do revendedor leem; só a gestão altera
drop policy if exists revenda_categoria_precos_ler on public.revenda_categoria_precos;
create policy revenda_categoria_precos_ler on public.revenda_categoria_precos for select using (true);
drop policy if exists revenda_categoria_precos_gestao on public.revenda_categoria_precos;
create policy revenda_categoria_precos_gestao on public.revenda_categoria_precos for all to authenticated
  using (public.eh_gestao()) with check (public.eh_gestao());
