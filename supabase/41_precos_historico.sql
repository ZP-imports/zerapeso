-- 41: histórico das alterações de preço feitas em Catálogo / Preços.

create table if not exists public.precos_historico (
  id uuid primary key default gen_random_uuid(),
  criado_em timestamptz not null default now(),
  por text,
  acao text,
  motivo text,
  itens jsonb not null default '[]'::jsonb
);

alter table public.precos_historico enable row level security;
drop policy if exists precos_historico_ler on public.precos_historico;
create policy precos_historico_ler on public.precos_historico for select to authenticated using (public.eh_admin());
drop policy if exists precos_historico_inserir on public.precos_historico;
create policy precos_historico_inserir on public.precos_historico for insert to authenticated with check (public.eh_admin());
