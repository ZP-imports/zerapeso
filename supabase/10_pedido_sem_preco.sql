-- =====================================================================
-- ZP Imports | Pedido sem preço (registro para o atendimento)
-- Produto sem variação/preço pode entrar no carrinho e ser enviado ao WhatsApp.
-- O pedido fica gravado com o item "valor a confirmar" (sem total e sem baixa de estoque),
-- para o atendente ter o histórico do que o cliente quer.
-- Rode depois do 01 ao 09. Pode rodar mais de uma vez.
-- Como usar: SQL Editor > nova consulta > cole TUDO > Run.
-- =====================================================================

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

create or replace function public.alterar_status_pedido(
  p_pedido bigint,
  p_status text,
  p_motivo text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  ped public.pedidos;
  quem text;
  titulo text;
  texto text;
  ev uuid;
  it jsonb;
begin
  if not public.eh_gestao() then raise exception 'Sem permissão para alterar pedidos.'; end if;
  select * into ped from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if p_status not in ('realizado','confirmado','preparacao','separacao','aguardando-programacao','programada','em-rota','entregue','tentativa','cancelado') then
    raise exception 'Status inválido.';
  end if;
  if ped.status in ('entregue','cancelado') then raise exception 'Este pedido já foi encerrado e não pode mais mudar de status.'; end if;
  if ped.status = p_status then raise exception 'O pedido já está neste status.'; end if;
  if p_status = 'cancelado' and coalesce(btrim(p_motivo), '') = '' then raise exception 'Informe o motivo do cancelamento.'; end if;

  select coalesce(nome, 'Equipe') into quem from public.perfis where id = auth.uid();

  -- cancelamento devolve o estoque (em unidades) uma única vez
  if p_status = 'cancelado' and ped.reduzido then
    for it in select * from jsonb_array_elements(ped.itens) loop
      if coalesce((it->>'semPreco')::boolean, false) then continue; end if;
      update public.produtos
         set estoque = estoque + (it->>'qty')::int * coalesce((it->>'unidades')::int, 1), atualizado_em = now()
       where id = (it->>'id')::int;
    end loop;
  end if;

  update public.pedidos
     set status = p_status,
         reduzido = case when p_status = 'cancelado' then false else reduzido end
   where id = p_pedido;

  titulo := case p_status
    when 'realizado' then 'Pedido recebido'
    when 'confirmado' then 'Pedido confirmado'
    when 'preparacao' then 'Pedido em preparação'
    when 'separacao' then 'Pedido em separação'
    when 'aguardando-programacao' then 'Aguardando programação da entrega'
    when 'programada' then 'Entrega programada'
    when 'em-rota' then 'Seu pedido saiu para entrega'
    when 'entregue' then 'Pedido entregue'
    when 'tentativa' then 'Tentativa de entrega'
    when 'cancelado' then 'Pedido cancelado'
  end;
  texto := case p_status
    when 'confirmado' then 'Confirmamos o seu pedido.'
    when 'preparacao' then 'Estamos preparando o seu pedido.'
    when 'separacao' then 'Estamos separando os itens do seu pedido.'
    when 'aguardando-programacao' then 'Estamos definindo a data e o horário da entrega.'
    when 'programada' then 'A entrega do seu pedido foi programada.'
    when 'em-rota' then 'O seu pedido saiu para entrega.'
    when 'entregue' then 'O seu pedido foi entregue. Obrigado pela compra.'
    when 'tentativa' then 'Tentamos entregar o seu pedido e não foi possível. Nossa equipe vai entrar em contato.'
    when 'cancelado' then 'O seu pedido foi cancelado.'
    else 'O status do seu pedido foi atualizado.'
  end;

  insert into public.pedido_eventos (pedido_id, tipo, de, para, publico, texto, motivo, por)
  values (p_pedido, 'status', ped.status, p_status, true, texto, nullif(btrim(coalesce(p_motivo, '')), ''), quem)
  returning id into ev;

  insert into public.pedido_avisos (pedido_id, titulo, texto, motivo, evento_id)
  values (p_pedido, titulo, texto, nullif(btrim(coalesce(p_motivo, '')), ''), ev);
end $$;
revoke all on function public.alterar_status_pedido(bigint, text, text) from public, anon;
grant execute on function public.alterar_status_pedido(bigint, text, text) to authenticated;
