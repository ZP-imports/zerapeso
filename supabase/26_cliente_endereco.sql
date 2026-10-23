-- 26_cliente_endereco.sql
-- Endereço completo no cadastro de clientes (aba Clientes): o CEP preenche rua, bairro, cidade e UF.
-- Só acrescenta colunas em public.clientes_importados. Não apaga nem muda nenhum dado.
-- Rode uma vez no SQL Editor da Supabase.

alter table public.clientes_importados
  add column if not exists endereco text,
  add column if not exists numero text,
  add column if not exists complemento text,
  add column if not exists bairro text,
  add column if not exists uf text;
