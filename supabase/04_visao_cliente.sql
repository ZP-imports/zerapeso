-- =====================================================================
-- ZP Imports | Fase 2 (site): o cliente lê os pedidos por uma "visão" segura
-- Motivo: a tabela de pedidos tem campos internos (observações da equipe,
-- mensagens de cobrança etc.). O cliente NÃO pode ler a tabela direto.
-- Ele lê a visão "pedidos_cliente", que só mostra os campos que ele pode ver
-- e só dos pedidos dele.
-- Rode DEPOIS do 01, 02 e 03. Não rode o 01 de novo depois deste.
-- Como usar: SQL Editor > nova consulta > cole TUDO > Run.
-- =====================================================================

-- Pergunta "este pedido é meu?" sem esbarrar nas regras de acesso
create or replace function public.eh_meu_pedido(p_id bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pedidos where id = p_id and usuario_id = auth.uid())
$$;
revoke all on function public.eh_meu_pedido(bigint) from public, anon;
grant execute on function public.eh_meu_pedido(bigint) to authenticated;

-- Eventos e avisos do cliente passam a usar essa pergunta
drop policy if exists eventos_ler_cliente on public.pedido_eventos;
create policy eventos_ler_cliente on public.pedido_eventos for select to authenticated
  using (publico and public.eh_meu_pedido(pedido_id));

drop policy if exists avisos_ler_cliente on public.pedido_avisos;
create policy avisos_ler_cliente on public.pedido_avisos for select to authenticated
  using (public.eh_meu_pedido(pedido_id));

-- O cliente deixa de ler a tabela de pedidos diretamente
drop policy if exists pedidos_ler_proprio on public.pedidos;

-- A visão do cliente: só os pedidos dele e só os campos que ele pode ver
create or replace view public.pedidos_cliente as
select p.id, p.usuario_id, p.seq, p.status, p.criado_em, p.atualizado_em,
       p.itens, p.entrega, p.pagamento, p.desconto, p.indicacao, p.rastreio,
       p.token, p.rota_id, p.entregador_id, p.conf_n
from public.pedidos p
where p.usuario_id = auth.uid();

revoke all on public.pedidos_cliente from public, anon;
grant select on public.pedidos_cliente to authenticated;

-- O link de pagamento só é entregue ao dono do pedido, quando o pedido já saiu para entrega
create or replace function public.link_pagamento_pedido(p_pedido bigint) returns text
language plpgsql stable security definer set search_path = public as $$
declare
  p public.pedidos;
begin
  select * into p from public.pedidos where id = p_pedido and usuario_id = auth.uid();
  if not found then return null; end if;
  if p.status not in ('em-rota', 'entregue', 'tentativa') or coalesce(p.pagamento->>'status', '') = 'pago' then
    return null;
  end if;
  return nullif(public.cfg('pagamento')->>'linkPag', '');
end $$;
revoke all on function public.link_pagamento_pedido(bigint) from public, anon;
grant execute on function public.link_pagamento_pedido(bigint) to authenticated;
