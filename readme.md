# Containerização do ProShop v2 com Docker e Docker Compose

## 1. Contextualização e Motivação

### Repositório de origem

- **Link:** https://github.com/bradtraversy/proshop-v2
- **Readme original:** [README](old_readme.md)
- **Projeto:** ProShop — aplicação de e-commerce full-stack construída com a stack MERN (MongoDB, Express, React, Node.js), de autoria de Brad Traversy.

### Cenário Atual

O projeto é executado de forma **manual e não containerizada**:

| Componente | Situação atual |
|---|---|
| Node.js | Instalado diretamente no host |
| Backend | Express `4.18.2` + Mongoose `7.0.1`, executado com `nodemon backend/server.js` (dev) ou `node backend/server.js` (prod) |
| Banco de dados | MongoDB externo — instalado localmente ou provisionado via MongoDB Atlas, referenciado por `MONGO_URI` em `.env` |
| Frontend | React `18.2.0` com Create React App (`react-scripts 5.0.1`), servido em modo dev por `react-scripts start` (porta 3000, com proxy para `:5000`) |
| Build de produção | `npm run build` gera `frontend/build`, que o próprio Express passa a servir como estático quando `NODE_ENV=production` |
| Upload de imagens | `multer` grava em `uploads/`; em produção o `server.js` serve os arquivos estáticos a partir de `/var/data/uploads` |
| Orquestração | Nenhuma — dependências e processos são geridos manualmente |

Com essa configuração, cada desenvolvedor precisa instalar Node.js e MongoDB localmente (ou apontar para um Atlas compartilhado), reproduzir manualmente as variáveis de ambiente, e o comportamento de upload de imagens diverge entre desenvolvimento e produção.

### Cenário Alvo

Migração para uma arquitetura **containerizada com Docker e Docker Compose**, composta por dois serviços orquestrados:

| Componente | Situação alvo |
|---|---|
| Runtime | Imagem `node:22-alpine` (LTS ativa/manutenção, compatível com Express 4, Mongoose 7 e o webpack 5 usado pelo `react-scripts 5`) |
| Backend + Frontend | Um único serviço `app`, construído com **Dockerfile multi-stage**: stage 1 compila o frontend (`npm run build`), stage 2 roda `node backend/server.js` em modo `production`, servindo API e estáticos pela mesma porta (5000) — preservando a arquitetura single-service já prevista no código |
| Banco de dados | Serviço `mongo`, imagem oficial `mongo:7`, com dados persistidos em volume nomeado (`mongo_data`) |
| Upload de imagens | Caminho de upload unificado via variável de ambiente `UPLOADS_DIR`, usada tanto pelo `multer` quanto pela rota estática do Express, persistido em volume nomeado (`uploads_data`) — elimina a divergência dev/prod existente hoje |
| Orquestração | `docker-compose.yml` único, subindo todo o ambiente (`app` + `mongo`) com `docker compose up`, incluindo healthcheck do Mongo e `depends_on` condicionado |

### Justificativa técnica e benefícios esperados

- **Paridade dev/produção:** todos os ambientes rodam a mesma imagem Node e a mesma versão de MongoDB.
- **Facilidade de onboarding:** um novo desenvolvedor sobe backend, frontend buildado e banco de dados com `docker compose up`, sem instalar Node.js, MongoDB ou gerenciar versões localmente.
- **Isolamento de dependências:** remove a necessidade de MongoDB instalado no host ou de credenciais de um Atlas compartilhado só para desenvolvimento local.
- **Correção de bug de arquitetura:** unifica o caminho de armazenamento de uploads entre dev e produção, hoje divergente.
- **Portabilidade:** a aplicação containerizada pode ser implantada em qualquer provedor com suporte a containers, não ficando presa a particularidades de uma única infraestrutura.
- **Base para CI/CD:** a mesma imagem construída em CI pode ser promovida para produção, reduzindo divergência entre o que é testado e o que é implantado.

---

## 2. Ambiente e Pré-requisitos

Antes de iniciar, garanta que a máquina onde a migração será executada possui:

| Ferramenta | Versão mínima | Verificação |
|---|---|---|
| Docker Engine | ≥ 24.x | `docker --version` |
| Docker Compose (plugin v2) | ≥ 2.20 | `docker compose version` |
| Git | qualquer versão recente | `git --version` |
| Portas livres no host | `5000` (app) e `27017` (mongo, opcional expor) | `lsof -i :5000` / `lsof -i :27017` |

Credenciais e valores necessários (já usados hoje pelo projeto, apenas reorganizados em um `.env` consumido pelo Compose):

- `JWT_SECRET` — qualquer string secreta para assinatura de tokens.
- `PAYPAL_CLIENT_ID` / `PAYPAL_APP_SECRET` — opcional para rodar a aplicação; necessário apenas para testar o fluxo de checkout via PayPal Sandbox ([developer.paypal.com](https://developer.paypal.com/)).
- `PAGINATION_LIMIT` — inteiro, ex. `8` (já usado pelo backend, ausente do `.env.example` do repositório mas documentado no `readme.md`).

Não é necessário instalar Node.js, npm ou MongoDB no host, pois toda a stack de execução passa a viver dentro dos containers. Node.js e Git seguem necessários apenas para clonar o repositório e (opcionalmente) rodar linters/editor localmente.

---

## 3. Roteiro de Migração

> Todos os comandos abaixo assumem que o terminal está na raiz do repositório clonado (`proshop-v2/`).

### Passo 1 — Confirmar o estado do repositório

```bash
git clone https://github.com/bradtraversy/proshop-v2.git
cd proshop-v2
git status
```

Crie uma branch dedicada para a migração, preservando a branch principal intacta para rollback:

```bash
git checkout -b feature/dockerize
```

### Passo 2 — Unificar o caminho de uploads (correção necessária antes de containerizar)

Hoje `backend/routes/uploadRoutes.js` grava em `uploads/` (relativo), enquanto `backend/server.js` serve, em produção, o caminho fixo `/var/data/uploads`. Para funcionar de forma consistente dentro de um container, introduza uma variável de ambiente única `UPLOADS_DIR`.

**`backend/routes/uploadRoutes.js`** — altere o `destination` do `multer.diskStorage`:

```diff
+ const uploadsDir = process.env.UPLOADS_DIR || 'uploads';
+
  const storage = multer.diskStorage({
    destination(req, file, cb) {
-     cb(null, 'uploads/');
+     cb(null, uploadsDir);
    },
```

**`backend/server.js`** — substitua o caminho de produção pela mesma variável:

```diff
+ const uploadsDir = process.env.UPLOADS_DIR || 'uploads';
+
  if (process.env.NODE_ENV === 'production') {
    const __dirname = path.resolve();
-   app.use('/uploads', express.static('/var/data/uploads'));
+   app.use('/uploads', express.static(path.join(__dirname, uploadsDir)));
    app.use(express.static(path.join(__dirname, '/frontend/build')));
    ...
  } else {
    const __dirname = path.resolve();
-   app.use('/uploads', express.static(path.join(__dirname, '/uploads')));
+   app.use('/uploads', express.static(path.join(__dirname, uploadsDir)));
    ...
  }
```

Isso torna o diretório de uploads configurável e idêntico em dev/prod, permitindo montar um único volume Docker para ambos os casos.

### Passo 3 — Criar o `.dockerignore`

Na raiz do projeto, crie `.dockerignore` para manter o contexto de build enxuto e evitar copiar artefatos locais para dentro da imagem:

```
node_modules
frontend/node_modules
frontend/build
uploads
.git
.env
npm-debug.log*
*.md
```

### Passo 4 — Criar o `Dockerfile` (multi-stage)

Na raiz do projeto, crie `Dockerfile`:

```dockerfile
# ---- Stage 1: build do frontend ----
FROM node:22-alpine AS frontend-build
WORKDIR /app/frontend
COPY frontend/package*.json ./
RUN npm ci
COPY frontend/ ./
RUN npm run build

# ---- Stage 2: runtime (backend + estáticos do frontend) ----
FROM node:22-alpine AS runtime
ENV NODE_ENV=production
WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev

COPY backend/ ./backend/
COPY --from=frontend-build /app/frontend/build ./frontend/build

RUN mkdir -p /app/uploads
VOLUME ["/app/uploads"]

EXPOSE 5000
CMD ["node", "backend/server.js"]
```

Esse Dockerfile reflete o `build` script já existente em `package.json` (`npm install && npm install --prefix frontend && npm run build --prefix frontend`), mas separado em estágios para manter a imagem final sem as dependências de build do React (menor e mais segura).

### Passo 5 — Criar o `docker-compose.yml`

Na raiz do projeto, crie `docker-compose.yml`:

```yaml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
    image: proshop-v2-app:latest
    restart: unless-stopped
    ports:
      - "5000:5000"
    env_file:
      - .env
    environment:
      NODE_ENV: production
      MONGO_URI: mongodb://mongo:27017/proshop
      UPLOADS_DIR: uploads
    volumes:
      - uploads_data:/app/uploads
    depends_on:
      mongo:
        condition: service_healthy

  mongo:
    image: mongo:7
    restart: unless-stopped
    volumes:
      - mongo_data:/data/db
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  mongo_data:
  uploads_data:
```

> `MONGO_URI` aponta para o hostname do serviço `mongo`, substituindo a URI do Atlas usada em dev manual.

### Passo 6 — Criar o `.env` consumido pelo Compose

Baseado em `.env.example`, crie um `.env` na raiz (não versionado):

```
JWT_SECRET=troque-por-um-segredo-forte
PAYPAL_CLIENT_ID=seu_client_id_sandbox
PAYPAL_APP_SECRET=seu_app_secret_sandbox
PAYPAL_API_URL=https://api-m.sandbox.paypal.com
PAGINATION_LIMIT=8
```

`PORT`, `NODE_ENV`, `MONGO_URI` e `UPLOADS_DIR` já são definidos diretamente em `docker-compose.yml` e não precisam ser repetidos aqui.

### Passo 7 — Build e subida dos containers

```bash
docker compose build
docker compose up -d
docker compose ps
```

Acompanhe os logs até confirmar a conexão com o banco:

```bash
docker compose logs -f app
```

Saída esperada: `MongoDB Connected: mongo` seguido de `Server running in production mode on port 5000`.

### Passo 8 — Popular o banco de dados (seed)

O script `backend/seeder.js` já existe no projeto (`npm run data:import` / `data:destroy`). Execute-o dentro do container `app`:

```bash
docker compose exec app node backend/seeder
```

Para limpar os dados de exemplo:

```bash
docker compose exec app node backend/seeder -d
```

### Passo 9 — Acessar a aplicação

- Aplicação completa (frontend + API): [http://localhost:5000](http://localhost:5000)
- Health check simples da API: `curl http://localhost:5000/api/products`

---

## 4. Plano de Rollback e Testes de Validação

### Validação

Checklist para confirmar que a aplicação migrada está funcional e sem regressões em relação ao fluxo manual original:

1. **Containers saudáveis**
   ```bash
   docker compose ps
   ```
   Ambos os serviços (`app`, `mongo`) devem estar `Up`/`healthy`.

2. **API respondendo**
   ```bash
   curl -i http://localhost:5000/api/products
   ```
   Deve retornar `200 OK` com a lista de produtos (após o seed do Passo 8).

3. **Frontend servido corretamente**
   Acessar `http://localhost:5000` no navegador e confirmar o carregamento da home com o catálogo de produtos.

4. **Autenticação**
   Login com o usuário admin criado pelo `seeder.js` (`admin@email.com` / `123456`, conforme `backend/data/users.js`) e confirmar acesso ao painel `/admin/userlist`.

5. **Upload de imagem** (valida a correção do Passo 2)
   No painel de admin, editar um produto e enviar uma nova imagem. Confirmar que:
   - o upload retorna `200` com o caminho da imagem;
   - a imagem é exibida corretamente no catálogo (prova que o caminho de escrita do `multer` e o caminho de leitura estático do Express agora coincidem).

6. **Persistência de dados após reinício**
   ```bash
   docker compose restart
   ```
   Produtos, usuários e a imagem enviada no passo anterior devem continuar presentes — confirma que os volumes nomeados (`mongo_data`, `uploads_data`) estão funcionando.

7. **Fluxo de pedido completo**
   Adicionar produto ao carrinho, finalizar endereço/pagamento e confirmar criação do pedido em `/orderlist` (admin).

8. **Ausência de regressões nos logs**
   ```bash
   docker compose logs app --tail=100
   ```
   Sem stack traces não tratados durante o fluxo de teste acima.

Somente considerar a migração bem-sucedida quando **todos** os itens acima passarem.

### Rollback

Procedimento para reverter ao estado original em caso de falha durante a validação:

1. **Parar e remover os containers da migração**
   ```bash
   docker compose down
   ```
   Use `docker compose down -v` **apenas** se os dados de teste em `mongo_data`/`uploads_data` puderem ser descartados sem impacto — nunca em um ambiente com dados reais de produção sem backup prévio (ver item 4).

2. **Reverter as alterações de código**
   ```bash
   git checkout main
   git branch -D feature/dockerize   # opcional, apaga a branch de migração
   ```
   Como os Passos 2–6 foram feitos em uma branch isolada (`feature/dockerize`), a branch principal permanece no estado manual original, sem necessidade de reverter diffs manualmente.

3. **Restaurar a execução manual**
   ```bash
   npm install
   npm install --prefix frontend
   cp .env.example .env   # preencher com MONGO_URI de um MongoDB local ou Atlas
   npm run dev
   ```
   Isso restaura o fluxo original: backend via `nodemon` na porta 5000 e frontend via `react-scripts start` na porta 3000, exatamente como antes da migração.

4. **Se dados de produção já haviam sido migrados para o container `mongo`:**
   - Antes de qualquer rollback em ambiente com dados reais, execute `mongodump` contra o `mongo` do Compose:
     ```bash
     docker compose exec mongo mongodump --db=proshop --out=/data/db/backup
     docker cp $(docker compose ps -q mongo):/data/db/backup ./backup-pre-rollback
     ```
   - Restaure esse backup no MongoDB de destino (Atlas ou instância local) usando `mongorestore` antes de desligar o container, garantindo que nenhum pedido/usuário criado durante o período em Docker seja perdido.

5. **Critério de decisão para rollback:** acionar este procedimento se, após o Passo 9, qualquer item do checklist de Validação falhar de forma não corrigível em até uma iteração de ajuste no Dockerfile/Compose, ou se o serviço `mongo` não atingir o estado `healthy` por causa raiz não identificável em tempo hábil.
