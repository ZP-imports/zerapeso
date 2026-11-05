-- 38: o cliente altera o endereço de entrega direto na página "Acompanhe o seu pedido".
-- O endereço vale só para este pedido, vai para a parada do motoboy e fica no histórico.

create or replace function public.cliente_novo_endereco(p_codigo text, p_token text, p_dest jsonb, p_obs text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pid bigint;
  ped public.pedidos;
  erro text;
  dest jsonb;
begin
  begin
    pid := nullif(regexp_replace(coalesce(p_codigo, ''), '\D', '', 'g'), '')::bigint;
  exception when others then
    raise exception 'Link inválido.';
  end;
  if pid is null or coalesce(p_token, '') = '' then raise exception 'Link inválido.'; end if;
  select * into ped from public.pedidos where id = pid and token = p_token for update;
  if not found then raise exception 'Link inválido.'; end if;
  if ped.status in ('entregue', 'cancelado') then raise exception 'Este pedido já foi encerrado e o endereço não pode mais ser alterado.'; end if;
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
   where id = pid;
  insert into public.pedido_eventos (pedido_id, tipo, publico, texto, motivo, por)
  values (pid, 'edicao', true, 'Você informou um novo endereço de entrega para este pedido.',
          nullif(left(btrim(coalesce(p_obs, '')), 200), ''), 'Cliente');
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.cliente_novo_endereco(text, text, jsonb, text) from public;
grant execute on function public.cliente_novo_endereco(text, text, jsonb, text) to anon, authenticated;
