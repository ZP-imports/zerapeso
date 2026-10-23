-- 25_revendedor_pagamento_mensagens.sql
-- 1) forma de pagamento escolhida pelo revendedor no pedido;
-- 2) mensagem enviada pelo painel só para o perfil de um revendedor (revendedor_id vazio = aviso para todos).
-- Rode depois dos arquivos 19a, 19, 23 e 24.

alter table public.pedidos_revendedor
  add column if not exists forma_pagamento text;

alter table public.avisos_revendedores
  add column if not exists revendedor_id uuid references public.revendedores(id) on delete cascade;
create index if not exists avisos_revendedores_rev_idx on public.avisos_revendedores (revendedor_id);
