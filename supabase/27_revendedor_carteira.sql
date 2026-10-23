-- 27_revendedor_carteira.sql
-- Revendedor de carteira (paga parcelado): guarda as parcelas e o status de pagamento no pedido do revendedor.
-- Só acrescenta colunas em public.pedidos_revendedor. Não apaga nem muda nenhum dado.
-- Rode uma vez no SQL Editor da Supabase.

alter table public.pedidos_revendedor
  add column if not exists pag_prev jsonb,
  add column if not exists pag_status text default 'pendente',
  add column if not exists pag_obs text;
