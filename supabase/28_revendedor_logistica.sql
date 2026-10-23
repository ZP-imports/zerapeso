-- 28_revendedor_logistica.sql
-- Liga o pedido do revendedor à operação do Wesley: ao clicar "Enviar para a logística", o pedido vira um
-- pedido normal (separação, rota, etiqueta, estoque, pagamento/Carteira) e o status volta sozinho para o portal.
-- Só acrescenta coluna/função/gatilho. Não apaga nem muda nenhum dado. Rode uma vez no SQL Editor.

alter table public.pedidos_revendedor
  add column if not exists pedido_id bigint references public.pedidos(id) on delete set null;

create or replace function public.enviar_pedido_revendedor(p_id uuid) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  pr public.pedidos_revendedor%rowtype;
  rv public.revendedores%rowtype;
  novo bigint;
  quem text;
  itens jsonb := '[]'::jsonb;
  it jsonb;
  ent jsonb;
  dest jsonb;
  ex jsonb;
  cart boolean;
begin
  if not public.eh_gestao() then raise exception 'Sem permissão.'; end if;
  select * into pr from public.pedidos_revendedor where id = p_id;
  if not found then raise exception 'Pedido do revendedor não encontrado.'; end if;
  if pr.pedido_id is not null then return pr.pedido_id; end if;
  if pr.status = 'cancelado' then raise exception 'Este pedido está cancelado.'; end if;
  select * into rv from public.revendedores where id = pr.revendedor_id;
  select coalesce(nome, 'Equipe') into quem from public.perfis where id = auth.uid();

  for it in select * from jsonb_array_elements(coalesce(pr.itens, '[]'::jsonb)) loop
    itens := itens || jsonb_build_array(jsonb_build_object(
      'id', coalesce(nullif(it->>'produto_id', '')::int, 0),
      'var', it->>'id',
      'name', coalesce(it->>'nome', 'Produto'),
      'base', coalesce(it->>'nome', 'Produto'),
      'opt', '',
      'qty', coalesce((it->>'qty')::numeric, 1),
      'unit', coalesce((it->>'preco')::numeric, 0),
      'unidades', 1));
  end loop;

  if pr.entrega is not null and coalesce(pr.entrega->>'nome', '') <> '' then
    dest := jsonb_build_object(
      'rua', coalesce(pr.entrega->>'endereco', ''), 'num', coalesce(pr.entrega->>'numero', ''),
      'comp', coalesce(pr.entrega->>'complemento', ''), 'bairro', coalesce(pr.entrega->>'bairro', ''),
      'cidade', coalesce(pr.entrega->>'cidade', ''), 'uf', coalesce(pr.entrega->>'uf', ''),
      'cep', coalesce(pr.entrega->>'cep', ''), 'ref', '');
    ent := jsonb_build_object('nome', pr.entrega->>'nome', 'fone', regexp_replace(coalesce(pr.entrega->>'telefone', ''), '\D', '', 'g'),
      'dest', dest, 'data', '', 'turno', '', 'obs', 'Entrega direta para o cliente do revendedor ' || coalesce(rv.nome, ''));
  else
    dest := jsonb_build_object('rua', '', 'num', '', 'comp', '', 'bairro', '', 'cidade', coalesce(rv.cidade, ''), 'uf', '', 'cep', '', 'ref', '');
    ent := jsonb_build_object('nome', coalesce(rv.nome, ''), 'fone', regexp_replace(coalesce(rv.telefone, ''), '\D', '', 'g'),
      'dest', dest, 'data', '', 'turno', '', 'obs', 'Pedido do revendedor ' || coalesce(rv.nome, ''));
  end if;

  cart := coalesce((rv.config->>'carteira')::boolean, false);
  ex := jsonb_build_object('revendedor', true, 'revendedor_id', pr.revendedor_id, 'revendedor_nome', coalesce(rv.nome, ''),
    'revendedor_fone', regexp_replace(coalesce(rv.telefone, ''), '\D', '', 'g'), 'ped_rev_id', pr.id, 'manual', true);
  if cart then
    ex := ex || jsonb_build_object('pag_prev', coalesce(pr.pag_prev, '[{"data":"","pago":false,"pago_em":null}]'::jsonb));
  end if;

  insert into public.pedidos (usuario_id, seq, status, itens, entrega, pagamento, extra)
  values (auth.uid(), 1, 'realizado', itens, ent,
    jsonb_build_object('modo', 'link', 'status', coalesce(nullif(pr.pag_status, ''), 'pendente'), 'taxaEntrega', 0,
      'preferencia', coalesce(pr.forma_pagamento, '')),
    ex)
  returning id into novo;

  update public.pedidos_revendedor set pedido_id = novo where id = pr.id;

  begin
    perform public.alterar_status_pedido(novo, 'confirmado', null);
  exception when others then
    null; -- se o estoque ou outra regra impedir, o pedido fica "realizado" e a equipe confirma na tela de Pedidos
  end;

  insert into public.pedido_eventos (pedido_id, tipo, publico, texto, por)
  values (novo, 'status', false, 'Pedido do revendedor ' || coalesce(rv.nome, '') || ' enviado para a logística.', coalesce(quem, 'Equipe'));

  return novo;
end $$;

revoke all on function public.enviar_pedido_revendedor(uuid) from public, anon;
grant execute on function public.enviar_pedido_revendedor(uuid) to authenticated;

-- o andamento do pedido (e o pagamento) volta sozinho para o portal do revendedor
create or replace function public.sincronizar_pedido_revendedor() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  st text;
begin
  if new.extra ? 'ped_rev_id' and (new.extra->>'ped_rev_id') is not null then
    st := case new.status
      when 'realizado' then 'novo'
      when 'confirmado' then 'confirmado'
      when 'preparacao' then 'confirmado'
      when 'separacao' then 'em_separacao'
      when 'aguardando-programacao' then 'em_separacao'
      when 'programada' then 'em_separacao'
      when 'em-rota' then 'em_rota'
      when 'tentativa' then 'em_rota'
      when 'entregue' then 'entregue'
      when 'cancelado' then 'cancelado'
      else null end;
    update public.pedidos_revendedor
       set status = coalesce(st, status),
           pag_status = case when new.pagamento->>'status' = 'pago' then 'pago' else 'pendente' end,
           pag_prev = coalesce(new.extra->'pag_prev', pag_prev)
     where id = (new.extra->>'ped_rev_id')::uuid;
  end if;
  return new;
end $$;

drop trigger if exists pedidos_sincroniza_revendedor on public.pedidos;
create trigger pedidos_sincroniza_revendedor
  after update of status, pagamento, extra on public.pedidos
  for each row execute function public.sincronizar_pedido_revendedor();
