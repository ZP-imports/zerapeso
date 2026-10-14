-- =====================================================================
-- ZP Imports | Variações sem preço
-- 1) A variação pode ficar sem preço (preço vazio = valor a confirmar no atendimento).
-- 2) Cadastra as variações dos injetáveis: "Caixa fechada c/ 4 Ampolas" e "Ampola por Unidade"
--    (a Retatrutida só tem "Unidade").
-- 3) O pedido aceita variação sem preço (fica "a confirmar", sem baixa de estoque).
-- Rode depois do 01 ao 10. Pode rodar mais de uma vez.
-- Como usar: SQL Editor > nova consulta > cole TUDO > Run.
-- =====================================================================

alter table public.produto_variacoes alter column preco drop not null;

insert into public.produto_variacoes (produto_id, nome, unidades, preco, ordem)
select p.id, 'Caixa fechada c/ 4 Ampolas', 4, null, 1
  from public.produtos p
 where p.id in (101, 102, 104, 105, 106, 107)
   and not exists (select 1 from public.produto_variacoes v where v.produto_id = p.id and v.nome = 'Caixa fechada c/ 4 Ampolas');

insert into public.produto_variacoes (produto_id, nome, unidades, preco, ordem)
select p.id, 'Ampola por Unidade', 1, null, 2
  from public.produtos p
 where p.id in (101, 102, 104, 105, 106, 107)
   and not exists (select 1 from public.produto_variacoes v where v.produto_id = p.id and v.nome = 'Ampola por Unidade');

insert into public.produto_variacoes (produto_id, nome, unidades, preco, ordem)
select p.id, 'Unidade', 1, null, 1
  from public.produtos p
 where p.id = 103
   and not exists (select 1 from public.produto_variacoes v where v.produto_id = p.id);

create or replace function public.criar_pedido(
  p_itens jsonb,
  p_entrega jsonb,
  p_codigo text default null,
  p_usar_credito boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  eu public.perfis;
  logi jsonb := public.cfg('logistica');
  prim jsonb := public.cfg('primeira_compra');
  hoje date := public.hoje_br();
  linha jsonb;
  prod public.produtos;
  vr public.produto_variacoes;
  qtd int;
  un int;
  opt text;
  pag text;
  deduziu boolean := false;
  itens jsonb := '[]'::jsonb;
  subtotal numeric := 0;
  unit numeric;
  data_ent date;
  turno text;
  erro text;
  dest jsonb;
  sec jsonb;
  entrega jsonb;
  v_prim numeric := 0;
  v_ind numeric := 0;
  v_cred numeric := 0;
  pct_prim numeric;
  ind jsonb;
  cred jsonb;
  d_tipo text;
  d_pct numeric;
  d_valor numeric := 0;
  desconto jsonb;
  indicacao jsonb;
  seq_novo int;
  novo public.pedidos;
begin
  if uid is null then raise exception 'Entre na sua conta para finalizar o pedido.'; end if;
  select * into eu from public.perfis where id = uid and ativo;
  if not found then raise exception 'Conta não encontrada.'; end if;
  if btrim(eu.nome) = '' or eu.fone is null then raise exception 'Complete o seu cadastro (nome e telefone) antes de finalizar.'; end if;
  erro := public.erro_endereco(eu.endereco);
  if erro is not null then raise exception 'Complete o endereço principal: %', erro; end if;

  -- itens: o preço vem da tabela de produtos
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'O carrinho está vazio.';
  end if;
  for linha in select * from jsonb_array_elements(p_itens) loop
    begin
      qtd := (linha->>'qty')::int;
    exception when others then
      raise exception 'Quantidade inválida.';
    end;
    if qtd is null or qtd < 1 or qtd > 99 then raise exception 'Quantidade inválida.'; end if;
    if linha ? 'var' then
      begin
        select * into vr from public.produto_variacoes where id = (linha->>'var')::uuid and ativo;
      exception when others then
        raise exception 'Um dos produtos não está mais disponível.';
      end;
      if not found then raise exception 'Um dos produtos não está mais disponível.'; end if;
      select * into prod from public.produtos where id = vr.produto_id and ativo for update;
      if not found then raise exception 'Um dos produtos não está mais disponível.'; end if;
      if vr.preco is null then
        -- variação sem preço: só registro do que o cliente quer (valor a confirmar), sem baixa de estoque
        itens := itens || jsonb_build_array(jsonb_build_object(
          'id', prod.id, 'var', vr.id, 'sku', prod.sku,
          'name', prod.nome || ' (' || vr.nome || ')',
          'base', prod.nome, 'opt', vr.nome, 'qty', qtd, 'unit', 0, 'unidades', vr.unidades, 'semPreco', true));
      else
        un := vr.unidades * qtd;
        if prod.estoque < un then raise exception 'Estoque insuficiente para % (%).', prod.nome, vr.nome; end if;
        update public.produtos set estoque = estoque - un, atualizado_em = now() where id = prod.id;
        deduziu := true;
        unit := coalesce(vr.preco_promo, vr.preco);
        subtotal := subtotal + unit * qtd;
        itens := itens || jsonb_build_array(jsonb_build_object(
          'id', prod.id, 'var', vr.id, 'sku', prod.sku,
          'name', prod.nome || ' (' || vr.nome || ')',
          'base', prod.nome, 'opt', vr.nome, 'qty', qtd, 'unit', unit, 'unidades', vr.unidades));
      end if;
    else
      -- produto sem preço: entra no pedido só como registro do que o cliente quer (valor a confirmar no atendimento)
      select * into prod from public.produtos where id = (linha->>'id')::int and ativo;
      if not found then raise exception 'Um dos produtos não está mais disponível.'; end if;
      if exists (select 1 from public.produto_variacoes where produto_id = prod.id and ativo) then
        raise exception 'Escolha uma das opções do produto %.', prod.nome;
      end if;
      itens := itens || jsonb_build_array(jsonb_build_object(
        'id', prod.id, 'sku', prod.sku, 'name', prod.nome || ' (Unidade)',
        'base', prod.nome, 'opt', 'Unidade', 'qty', qtd, 'unit', 0, 'unidades', 1, 'semPreco', true));
    end if;
  end loop;

  -- forma de pagamento preferida
  pag := coalesce(p_entrega->>'pagamento', '');
  if pag not in ('pix','credito','debito') then raise exception 'Escolha a forma de pagamento.'; end if;

  -- entrega: data, turno e endereço
  begin
    data_ent := (p_entrega->>'data')::date;
  exception when others then
    raise exception 'Data de entrega inválida.';
  end;
  if data_ent is null then raise exception 'Escolha a data desejada para receber o pedido.'; end if;
  turno := coalesce(p_entrega->>'turno', '');
  if turno not in ('manha','tarde','noite') or coalesce(logi->'turnos'->>turno, 'false') <> 'true' then
    raise exception 'Escolha um turno disponível.';
  end if;
  if data_ent < hoje + coalesce((logi->>'antecedencia')::int, 1) then
    raise exception 'A data deve ser a partir de %.', to_char(hoje + coalesce((logi->>'antecedencia')::int, 1), 'DD/MM/YYYY');
  end if;
  if data_ent > hoje + coalesce((logi->>'janela')::int, 30) then
    raise exception 'A data deve ser até %.', to_char(hoje + coalesce((logi->>'janela')::int, 30), 'DD/MM/YYYY');
  end if;
  if not ((logi->'dias') @> to_jsonb(extract(dow from data_ent)::int)) then
    raise exception 'Não entregamos neste dia da semana. Escolha outra data.';
  end if;
  if exists (select 1 from jsonb_array_elements_text(coalesce(logi->'bloqueados', '[]'::jsonb)) b where b = data_ent::text) then
    raise exception 'Não há entregas nesta data. Escolha outra.';
  end if;
  sec := p_entrega->'sec';
  if sec is not null and jsonb_typeof(sec) = 'object' then
    erro := public.erro_endereco(sec, 'Endereço secundário: ');
    if erro is not null then raise exception '%', erro; end if;
    dest := jsonb_set(sec, '{uf}', to_jsonb(upper(sec->>'uf')));
  else
    sec := null;
    dest := eu.endereco;
  end if;

  -- desconto: um só por pedido, vale o maior (empate: indicação, depois crédito, depois primeira compra)
  if not exists (select 1 from public.pedidos where usuario_id = uid and status <> 'cancelado') then
    pct_prim := coalesce((prim->>'pct')::numeric, 0);
    v_prim := round(subtotal * pct_prim / 100, 2);
  end if;
  if p_codigo is not null and btrim(p_codigo) <> '' then
    ind := public.validar_indicacao(p_codigo);
    if coalesce((ind->>'ok')::boolean, false) then
      v_ind := round(subtotal * (ind->>'pct')::numeric / 100, 2);
    else
      ind := null;
    end if;
  end if;
  if p_usar_credito then
    cred := public.creditos_de(uid);
    if coalesce((cred->>'disponiveis')::int, 0) > 0 then
      v_cred := round(subtotal * (cred->>'pct')::numeric / 100, 2);
    end if;
  end if;
  if v_ind > 0 and v_ind >= v_cred and v_ind >= v_prim then
    d_tipo := 'indicacao'; d_valor := v_ind; d_pct := (ind->>'pct')::numeric;
  elsif v_cred > 0 and v_cred >= v_prim then
    d_tipo := 'credito'; d_valor := v_cred; d_pct := (cred->>'pct')::numeric;
  elsif v_prim > 0 then
    d_tipo := 'primeira'; d_valor := v_prim; d_pct := pct_prim;
  end if;
  if d_tipo is not null then
    desconto := jsonb_build_object('tipo', d_tipo, 'pct', d_pct, 'valor', d_valor);
    if d_tipo = 'indicacao' then
      desconto := desconto || jsonb_build_object('code', ind->>'codigo');
      indicacao := jsonb_build_object('owner', ind->>'owner', 'code', ind->>'codigo');
    end if;
  end if;

  select coalesce(max(seq), 0) + 1 into seq_novo from public.pedidos where usuario_id = uid;
  entrega := jsonb_build_object(
    'nome', btrim(eu.nome || ' ' || eu.sobrenome), 'fone', eu.fone,
    'principal', eu.endereco, 'secundario', sec, 'dest', dest,
    'data', data_ent::text, 'turno', turno, 'obs', left(btrim(coalesce(p_entrega->>'obs', '')), 500));

  insert into public.pedidos (usuario_id, seq, itens, entrega, desconto, indicacao, reduzido, pagamento)
  values (uid, seq_novo, itens, entrega, desconto, indicacao, deduziu,
    '{"modo":"link","status":"pendente","taxaEntrega":0}'::jsonb || jsonb_build_object('preferencia', pag))
  returning * into novo;

  insert into public.pedido_eventos (pedido_id, tipo, para, publico, texto, por)
  values (novo.id, 'status', 'realizado', true, 'Recebemos o seu pedido.', 'Cliente');

  if d_tipo = 'indicacao' and eu.indicado_por is null then
    update public.perfis set indicado_por = (ind->>'owner')::uuid where id = uid;
  end if;

  return jsonb_build_object(
    'id', novo.id,
    'codigo', 'ZP-' || lpad(novo.id::text, 6, '0'),
    'token', novo.token,
    'subtotal', subtotal,
    'desconto', coalesce(d_valor, 0),
    'total', subtotal - coalesce(d_valor, 0),
    'tipo_desconto', d_tipo);
end $$;
revoke all on function public.criar_pedido(jsonb, jsonb, text, boolean) from public, anon;
grant execute on function public.criar_pedido(jsonb, jsonb, text, boolean) to authenticated;
