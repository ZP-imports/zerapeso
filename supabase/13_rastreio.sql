-- =====================================================================
-- ZP Imports | Rastreio do pedido
-- rastrear_pedido: acompanhamento sem login, por link com código + token do pedido.
-- Só devolve o necessário (status, itens, previsão, cidade e o histórico público).
-- Não devolve nome completo, telefone nem endereço do cliente, nem dados do entregador.
-- Rode depois do 01 ao 12. Pode rodar mais de uma vez.
-- Como usar: SQL Editor > nova consulta > cole TUDO > Run.
-- =====================================================================

create or replace function public.rastrear_pedido(p_codigo text, p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  pid bigint;
  ped public.pedidos;
  evs jsonb;
begin
  begin
    pid := nullif(regexp_replace(coalesce(p_codigo, ''), '\D', '', 'g'), '')::bigint;
  exception when others then
    return null;
  end;
  if pid is null or coalesce(p_token, '') = '' then return null; end if;
  select * into ped from public.pedidos where id = pid and token = p_token;
  if not found then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object('t', e.t, 'texto', e.texto, 'motivo', e.motivo) order by e.t), '[]'::jsonb)
    into evs from public.pedido_eventos e where e.pedido_id = pid and e.publico;
  return jsonb_build_object(
    'codigo', 'ZP-' || lpad(ped.id::text, 6, '0'),
    'status', ped.status,
    'criado_em', ped.criado_em,
    'itens', (select coalesce(jsonb_agg(jsonb_build_object('name', i->>'name', 'qty', (i->>'qty')::int, 'semPreco', coalesce((i->>'semPreco')::boolean, false))), '[]'::jsonb) from jsonb_array_elements(ped.itens) i),
    'data', ped.entrega->>'data',
    'turno', ped.entrega->>'turno',
    'cidade', ped.entrega->'dest'->>'cidade',
    'uf', ped.entrega->'dest'->>'uf',
    'pago', coalesce(ped.pagamento->>'status', '') = 'pago',
    'eventos', evs);
end $$;
revoke all on function public.rastrear_pedido(text, text) from public;
grant execute on function public.rastrear_pedido(text, text) to anon, authenticated;
