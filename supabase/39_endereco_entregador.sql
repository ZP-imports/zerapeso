-- 39: cliente altera o endereço e avisa o entregador pelo WhatsApp dela.
-- O entregador recebe um link só daquela entrega: finaliza (com foto) como numa rota normal,
-- dá baixa no mesmo pedido da rota dele e segue o resto da rota.
-- Usa as funções que já existem (rota_entregador_acao e rota_entregador_foto), então a regra de finalizar é a mesma.

create or replace function public.cliente_novo_endereco(p_codigo text, p_token text, p_dest jsonb, p_obs text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pid bigint;
  ped public.pedidos;
  erro text;
  dest jsonb;
  tk text;
  w text;
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
  tk := coalesce(nullif(ped.extra->>'ent_tok', ''), md5(random()::text || clock_timestamp()::text || pid::text));
  update public.pedidos
     set entrega = entrega || jsonb_build_object('dest', dest),
         extra = coalesce(extra, '{}'::jsonb)
                 || jsonb_build_object('end_alt', 'respondido', 'end_alt_em', now(), 'end_ant', ped.entrega->'dest',
                                       'end_alt_obs', left(btrim(coalesce(p_obs, '')), 200), 'ent_tok', tk)
   where id = pid;
  insert into public.pedido_eventos (pedido_id, tipo, publico, texto, motivo, por)
  values (pid, 'edicao', true, 'Você informou um novo endereço de entrega para este pedido.',
          nullif(left(btrim(coalesce(p_obs, '')), 200), ''), 'Cliente');
  if ped.entregador_id is not null and ped.status in ('programada', 'em-rota', 'tentativa') then
    select whats into w from public.entregadores where id = ped.entregador_id;
  end if;
  return jsonb_build_object('ok', true, 'tok', tk, 'whats', w);
end $$;

-- a página "Acompanhe o seu pedido" pergunta se o endereço foi alterado e para quem enviar o aviso
create or replace function public.cliente_endereco_aviso(p_codigo text, p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  pid bigint;
  ped public.pedidos;
  w text;
begin
  begin
    pid := nullif(regexp_replace(coalesce(p_codigo, ''), '\D', '', 'g'), '')::bigint;
  exception when others then
    return null;
  end;
  if pid is null or coalesce(p_token, '') = '' then return null; end if;
  select * into ped from public.pedidos where id = pid and token = p_token;
  if not found then return null; end if;
  if ped.entregador_id is not null and ped.status in ('programada', 'em-rota', 'tentativa') then
    select whats into w from public.entregadores where id = ped.entregador_id;
  end if;
  return jsonb_build_object(
    'alterado', coalesce(ped.extra->>'end_alt', '') = 'respondido' and ped.status not in ('entregue', 'cancelado'),
    'whats', w,
    'tok', ped.extra->>'ent_tok');
end $$;

-- página do entregador com SÓ aquela entrega
create or replace function public.parada_entregador(p_pedido bigint, p_tok text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  ped public.pedidos;
  sai boolean := false;
begin
  if coalesce(p_tok, '') = '' then return null; end if;
  select * into ped from public.pedidos where id = p_pedido and coalesce(extra->>'ent_tok', '') = p_tok;
  if not found then return null; end if;
  if ped.rota_id is not null then
    select (saiu_em is not null) into sai from public.rotas where id = ped.rota_id;
  end if;
  return jsonb_build_object(
    'pedido', ped.id, 'status', ped.status, 'saiu', coalesce(sai, false), 'chegou_em', ped.chegou_em,
    'nome', ped.entrega->>'nome', 'fone', ped.entrega->>'fone', 'dest', ped.entrega->'dest',
    'turno', ped.entrega->>'turno');
end $$;

create or replace function public.parada_acao(p_pedido bigint, p_tok text, p_acao text) returns void
language plpgsql security definer set search_path = public as $$
declare
  ped public.pedidos;
  r public.rotas;
begin
  if coalesce(p_tok, '') = '' then raise exception 'Link inválido.'; end if;
  select * into ped from public.pedidos where id = p_pedido and coalesce(extra->>'ent_tok', '') = p_tok;
  if not found then raise exception 'Link inválido.'; end if;
  if ped.rota_id is null then raise exception 'Este pedido ainda não está em uma rota.'; end if;
  select * into r from public.rotas where id = ped.rota_id;
  if not found then raise exception 'Rota não encontrada.'; end if;
  if p_acao = 'entregue' and ped.chegou_em is null then raise exception 'Registre a chegada com a foto do local antes de finalizar.'; end if;
  perform public.rota_entregador_acao(r.id, r.token, p_pedido, p_acao);
end $$;

create or replace function public.parada_foto(p_pedido bigint, p_tok text, p_foto text) returns void
language plpgsql security definer set search_path = public as $$
declare
  ped public.pedidos;
  r public.rotas;
begin
  if coalesce(p_tok, '') = '' then raise exception 'Link inválido.'; end if;
  select * into ped from public.pedidos where id = p_pedido and coalesce(extra->>'ent_tok', '') = p_tok;
  if not found then raise exception 'Link inválido.'; end if;
  if ped.rota_id is null then raise exception 'Este pedido ainda não está em uma rota.'; end if;
  select * into r from public.rotas where id = ped.rota_id;
  if not found then raise exception 'Rota não encontrada.'; end if;
  perform public.rota_entregador_foto(r.id, r.token, p_pedido, p_foto);
  perform public.rota_entregador_acao(r.id, r.token, p_pedido, 'cheguei');
end $$;

revoke all on function public.cliente_novo_endereco(text, text, jsonb, text) from public;
revoke all on function public.cliente_endereco_aviso(text, text) from public;
revoke all on function public.parada_entregador(bigint, text) from public;
revoke all on function public.parada_acao(bigint, text, text) from public;
revoke all on function public.parada_foto(bigint, text, text) from public;
grant execute on function public.cliente_novo_endereco(text, text, jsonb, text) to anon, authenticated;
grant execute on function public.cliente_endereco_aviso(text, text) to anon, authenticated;
grant execute on function public.parada_entregador(bigint, text) to anon, authenticated;
grant execute on function public.parada_acao(bigint, text, text) to anon, authenticated;
grant execute on function public.parada_foto(bigint, text, text) to anon, authenticated;
