-- 29_catalogo_repasse.sql
-- Catálogo de repasse: o Wesley define UM valor de repasse por variação de produto e cada revendedor
-- paga esse valor menos a porcentagem dele (a menos que tenha preço exclusivo).
-- Só cria uma tabela nova. Não muda nem apaga nada. Rode uma vez no SQL Editor.

create table if not exists public.catalogo_revenda (
  variacao_id uuid primary key references public.produto_variacoes(id) on delete cascade,
  preco numeric(10,2) not null check (preco >= 0),
  atualizado_em timestamptz not null default now()
);

alter table public.catalogo_revenda enable row level security;

-- o portal do revendedor lê o catálogo; só a gestão altera
drop policy if exists catalogo_revenda_ler on public.catalogo_revenda;
create policy catalogo_revenda_ler on public.catalogo_revenda for select using (true);
drop policy if exists catalogo_revenda_gestao on public.catalogo_revenda;
create policy catalogo_revenda_gestao on public.catalogo_revenda for all to authenticated
  using (public.eh_gestao()) with check (public.eh_gestao());
