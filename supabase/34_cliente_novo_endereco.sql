-- 34: o cliente informa um novo endereço de entrega (só neste pedido) por um link enviado pela loja.
-- O Wesley libera o link no pedido; o cliente preenche; o endereço da parada do motoboy muda junto.

create or replace function public.endereco_pedido_cliente(p_pedido bigint, p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ped public.pedidos;
begin
  if coalesce(p_token, '') = '' then return null; end if;
  select * into ped from public.pedidos where id = p_pedido and token = p_token;
  if not found then return null; end if;
  return jsonb_build_object(
    'nome', split_part(coalesce(ped.entrega->>'nome', ''), ' ', 1),
    'status', ped.status,
    'aberto', coalesce(ped.extra->>'end_alt', '') = 'aberto' and ped.status not in ('entregue', 'cancelado'),
    'dest', ped.entrega->'dest'
  );
end $$;

create or replace function public.cliente_alterar_endereco(p_pedido bigint, p_token text, p_dest jsonb, p_obs text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ped public.pedidos;
  erro text;
  dest jsonb;
  ev uuid;
begin
  if coalesce(p_token, '') = '' then raise exception 'Link inválido.'; end if;
  select * into ped from public.pedidos where id = p_pedido and token = p_token for update;
  if not found then raise exception 'Link inválido.'; end if;
  if ped.status in ('entregue', 'cancelado') then raise exception 'Este pedido já foi encerrado.'; end if;
  if coalesce(ped.extra->>'end_alt', '') <> 'aberto' then raise exception 'Este link não está mais disponível. Fale com a loja.'; end if;
  erro := public.erro_endereco(p_dest);
  if erro is not null then raise exception '%', erro; end if;
  dest := jsonb_build_object(
    'cep', left(btrim(p_dest->>'cep'), 12), 'uf', upper(left(btrim(p_dest->>'uf'), 2)),
    'cidade', left(btrim(p_dest->>'cidade'), 80), 'bairro', left(btrim(p_dest->>'bairro'), 80),
    'rua', left(btrim(p_dest->>'rua'), 120), 'num', left(btrim(p_dest->>'num'), 20),
    'comp', left(btrim(coalesce(p_dest->>'comp', '')), 60), 'ref', left(btrim(coalesce(p_dest->>'ref', '')), 120));
  update public.pedidos
     set entrega = entrega || jsonb_build_object('dest', dest),
         extra = coalesce(extra, '{}'::jsonb)
                 || jsonb_build_object('end_alt', 'respondido', 'end_alt_em', now(), 'end_ant', ped.entrega->'dest',
                                       'end_alt_obs', left(btrim(coalesce(p_obs, '')), 200))
   where id = p_pedido;
  insert into public.pedido_eventos (pedido_id, tipo, publico, texto, motivo, por)
  values (p_pedido, 'edicao', true, 'Você informou um novo endereço de entrega para este pedido.',
          nullif(left(btrim(coalesce(p_obs, '')), 200), ''), 'Cliente')
  returning id into ev;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.endereco_pedido_cliente(bigint, text) from public;
revoke all on function public.cliente_alterar_endereco(bigint, text, jsonb, text) from public;
grant execute on function public.endereco_pedido_cliente(bigint, text) to anon, authenticated;
grant execute on function public.cliente_alterar_endereco(bigint, text, jsonb, text) to anon, authenticated;
