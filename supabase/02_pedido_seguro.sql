-- =====================================================================
-- ZP Imports | Fase 2: pedido seguro
-- O preço, o desconto, o estoque e as datas de entrega são calculados AQUI,
-- no servidor. O navegador só diz quais produtos, quantas unidades e para onde.
-- Como usar: Supabase > SQL Editor > New query > cole TUDO > Run.
-- Pode ser executado mais de uma vez. Rode antes o 01_fundacao.sql.
-- =====================================================================

create or replace function public.hoje_br() returns date
language sql stable as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

create or replace function public.so_digitos(t text) returns text
language sql immutable as $$ select regexp_replace(coalesce(t, ''), '\D', '', 'g') $$;

create or replace function public.cfg(p_chave text) returns jsonb
language sql stable security definer set search_path = public as $$
  select valor from public.configuracao where chave = p_chave
$$;
revoke all on function public.cfg(text) from public, anon, authenticated;

-- Confere um endereço. Devolve a mensagem de erro, ou null se estiver certo.
create or replace function public.erro_endereco(e jsonb, pre text default '') returns text
language plpgsql immutable as $$
begin
  if e is null or jsonb_typeof(e) <> 'object' then return pre || 'Endereço não informado.'; end if;
  if length(public.so_digitos(e->>'cep')) <> 8 then return pre || 'CEP inválido (8 números).'; end if;
  if upper(coalesce(e->>'uf', '')) not in ('AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO') then
    return pre || 'Informe o estado (UF) válido.';
  end if;
  if btrim(coalesce(e->>'cidade', '')) = '' then return pre || 'Informe a cidade.'; end if;
  if btrim(coalesce(e->>'bairro', '')) = '' then return pre || 'Informe o bairro.'; end if;
  if btrim(coalesce(e->>'rua', '')) = '' then return pre || 'Informe a rua.'; end if;
  if btrim(coalesce(e->>'num', '')) = '' then return pre || 'Informe o número do imóvel.'; end if;
  return null;
end $$;

-- ---------------------------------------------------------------------
-- Crédito de indicação do próprio cliente (cada amigo que compra rende um crédito)
-- ---------------------------------------------------------------------
create or replace function public.creditos_de(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  amigo jsonb := public.cfg('amigo');
  lim int := coalesce((amigo->>'limite')::int, 10);
  ganhos numeric[];
  usados int;
  n int;
begin
  select coalesce(array_agg(pct order by criado_em), '{}'::numeric[]) into ganhos from (
    select p.criado_em,
           coalesce((p.desconto->>'pct')::numeric, (amigo->>'pct')::numeric) as pct,
           row_number() over (
             partition by date_trunc('month', p.criado_em at time zone 'America/Sao_Paulo')
             order by p.criado_em) as rn
    from public.pedidos p
    where (p.indicacao->>'owner')::uuid = p_user
      and p.status in ('confirmado','preparacao','separacao','aguardando-programacao','programada','em-rota','entregue','tentativa')
  ) t
  where rn <= lim;
  select count(*) into usados from public.pedidos
   where usuario_id = p_user and status <> 'cancelado' and desconto->>'tipo' = 'credito';
  n := coalesce(array_length(ganhos, 1), 0);
  return jsonb_build_object(
    'disponiveis', greatest(n - usados, 0),
    'pct', case when n > usados then ganhos[usados + 1] end);
end $$;
revoke all on function public.creditos_de(uuid) from public, anon, authenticated;

create or replace function public.meus_creditos() returns jsonb
language sql stable security definer set search_path = public as $$
  select public.creditos_de(auth.uid())
$$;
revoke all on function public.meus_creditos() from public, anon;
grant execute on function public.meus_creditos() to authenticated;

-- ---------------------------------------------------------------------
-- Confere um código de indicação (o site usa para mostrar a mensagem ao cliente)
-- ---------------------------------------------------------------------
create or replace function public.validar_indicacao(p_codigo text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  amigo jsonb := public.cfg('amigo');
  cod text := upper(btrim(coalesce(p_codigo, '')));
  eu public.perfis;
  dono public.perfis;
  lim int;
  usados int;
  hoje date := public.hoje_br();
begin
  if uid is null then return jsonb_build_object('ok', false, 'erro', 'Entre na sua conta para usar um código.'); end if;
  if cod = '' then return jsonb_build_object('ok', false, 'erro', 'Informe o código de indicação.'); end if;
  if amigo is null or not coalesce((amigo->>'ativa')::boolean, false)
     or hoje < (amigo->>'inicio')::date or hoje > (amigo->>'fim')::date then
    return jsonb_build_object('ok', false, 'erro', 'A campanha Amigo Emagrece Amigo não está ativa no momento.');
  end if;
  select * into dono from public.perfis where codigo_indicacao = cod;
  if not found then return jsonb_build_object('ok', false, 'erro', 'Código de indicação não encontrado.'); end if;
  select * into eu from public.perfis where id = uid;
  if dono.id = uid then return jsonb_build_object('ok', false, 'erro', 'Você não pode usar o seu próprio código.'); end if;
  if exists (select 1 from public.pedidos where usuario_id = uid and status <> 'cancelado') then
    return jsonb_build_object('ok', false, 'erro', 'O desconto de indicação vale só na primeira compra de quem foi indicado.');
  end if;
  if (public.so_digitos(eu.fone) <> '' and public.so_digitos(eu.fone) = public.so_digitos(dono.fone))
     or (public.so_digitos(eu.endereco->>'cep') <> ''
         and public.so_digitos(eu.endereco->>'cep') = public.so_digitos(dono.endereco->>'cep')
         and btrim(coalesce(eu.endereco->>'num', '')) = btrim(coalesce(dono.endereco->>'num', ''))) then
    return jsonb_build_object('ok', false, 'erro', 'Não foi possível aplicar: os dados parecem ser da mesma pessoa ou da mesma casa de quem indicou.');
  end if;
  lim := coalesce((amigo->>'limite')::int, 10);
  select count(*) into usados from public.pedidos
   where (indicacao->>'owner')::uuid = dono.id and status <> 'cancelado'
     and date_trunc('month', criado_em at time zone 'America/Sao_Paulo') = date_trunc('month', now() at time zone 'America/Sao_Paulo');
  if usados >= lim then
    return jsonb_build_object('ok', false, 'erro', 'Este código atingiu o limite de indicações deste mês. Peça ao seu amigo para indicar no mês que vem.');
  end if;
  return jsonb_build_object('ok', true, 'owner', dono.id, 'pct', (amigo->>'pct')::numeric, 'codigo', cod);
end $$;
revoke all on function public.validar_indicacao(text) from public, anon;
grant execute on function public.validar_indicacao(text) to authenticated;

-- ---------------------------------------------------------------------
-- Criar o pedido
--   p_itens   : [{"id":1,"qty":2,"opt":"Caixa com 1 caneta"}]   (preço NÃO é aceito do navegador)
--   p_entrega : {"data":"2026-10-20","turno":"manha","obs":"...","sec":{endereço} ou null}
-- ---------------------------------------------------------------------
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
  qtd int;
  opt text;
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
    select * into prod from public.produtos where id = (linha->>'id')::int and ativo for update;
    if not found then raise exception 'Um dos produtos não está mais disponível.'; end if;
    opt := coalesce(linha->>'opt', '');
    if prod.opcoes is not null and array_length(prod.opcoes, 1) > 0 then
      if not (opt = any (prod.opcoes)) then raise exception 'Escolha uma opção válida para %.', prod.nome; end if;
    else
      opt := '';
    end if;
    if prod.estoque < qtd then raise exception 'Estoque insuficiente para %.', prod.nome; end if;
    update public.produtos set estoque = estoque - qtd, atualizado_em = now() where id = prod.id;
    unit := coalesce(prod.preco_promo, prod.preco);
    subtotal := subtotal + unit * qtd;
    itens := itens || jsonb_build_array(jsonb_build_object(
      'id', prod.id, 'sku', prod.sku,
      'name', prod.nome || case when opt <> '' then ' (' || opt || ')' else '' end,
      'base', prod.nome, 'opt', opt, 'qty', qtd, 'unit', unit));
  end loop;

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

  insert into public.pedidos (usuario_id, seq, itens, entrega, desconto, indicacao, reduzido)
  values (uid, seq_novo, itens, entrega, desconto, indicacao, true)
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
