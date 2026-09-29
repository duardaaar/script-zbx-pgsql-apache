# Instalação automatizada do Zabbix 7.0 LTS

Script em Bash que instala e configura um servidor **Zabbix 7.0 LTS** completo em um único host, pronto para uso ao final da execução.

| Componente     | Tecnologia                          |
|----------------|-------------------------------------|
| Sistema        | Ubuntu 26.04 LTS                    |
| Banco de dados | PostgreSQL (versão do repositório do Ubuntu) |
| Servidor web   | Apache + PHP-FPM                    |
| Zabbix         | Server, Frontend e Agent 2          |

---

## Sumário

- [Requisitos](#requisitos)
- [Arquivos do repositório](#arquivos-do-repositório)
- [Instalação rápida](#instalação-rápida)
- [Parâmetros (.env)](#parâmetros-env)
- [O que o script faz](#o-que-o-script-faz)
- [Após a instalação](#após-a-instalação)
- [Executar novamente](#executar-novamente)
- [Remoção completa](#remoção-completa)
- [Solução de problemas](#solução-de-problemas)
- [Segurança](#segurança)

---

## Requisitos

- Ubuntu **26.04** recém-instalado (servidor ou VM dedicada)
- Acesso **root** ou usuário com `sudo`
- Acesso à internet (repositórios do Ubuntu e `repo.zabbix.com`)
- Recomendado para ambientes pequenos: **2 vCPU, 4 GB de RAM, 20 GB de disco**

> 💡 Se estiver usando VM, tire um **snapshot antes da instalação**. É a forma mais rápida de voltar ao estado inicial para testar novamente.

---

## Arquivos do repositório

| Arquivo              | Descrição                                                        |
|----------------------|------------------------------------------------------------------|
| `zabbix-server.bash` | Script de instalação                                             |
| `remove.bash`        | Remove **tudo** o que foi instalado (use apenas em testes)       |
| `.env.example`       | Modelo do arquivo de parâmetros                                  |
| `.gitignore`         | Impede que o `.env` (com a senha) seja enviado ao repositório   |

---

## Instalação rápida

**1. Clone o repositório no servidor**

```bash
git clone https://github.com/<seu-usuario>/<seu-repositorio>.git
cd <seu-repositorio>
```

**2. Crie o arquivo `.env` a partir do modelo**

```bash
cp .env.example .env
nano .env
```

Altere pelo menos a senha (`ZBX_DB_PASS`). Salve com `Ctrl+O`, `Enter` e saia com `Ctrl+X`.

**3. Proteja o arquivo** (ele contém a senha do banco)

```bash
chmod 600 .env
```

**4. Execute o instalador**

```bash
sudo bash zabbix-server.bash
```

Ao final, o script exibe o endereço de acesso e o status de cada serviço.

---

## Parâmetros (.env)

O script lê automaticamente o arquivo `.env` que estiver **na mesma pasta** dele.

```env
ZBX_DB_PASS=sua_senha_aqui
ZBX_DB_NAME=zabbix
ZBX_DB_USER=zabbix
ZBX_TZ=America/Sao_Paulo
ZBX_NAME=zbxserver
```

| Variável      | Descrição                                   | Padrão              |
|---------------|---------------------------------------------|---------------------|
| `ZBX_DB_PASS` | Senha do usuário do banco                   | *(perguntada na execução)* |
| `ZBX_DB_NAME` | Nome do banco de dados                      | `zabbix`            |
| `ZBX_DB_USER` | Usuário do banco de dados                   | `zabbix`            |
| `ZBX_TZ`      | Fuso horário do sistema e do PHP            | `America/Sao_Paulo` |
| `ZBX_NAME`    | Nome exibido no frontend do Zabbix          | hostname da máquina |

### Regras do `.env`

- O `.env` é **opcional**. Sem ele, o script usa os valores padrão e **pergunta a senha** durante a execução.
- Valores podem ser escritos com ou sem aspas: `ZBX_DB_PASS=abc`, `"abc"` ou `'abc'`.
- Linhas em branco e comentários (`#`) são ignorados.
- A senha pode ter caracteres especiais (`$`, `!`, `#`, `@`...), **exceto aspas simples (`'`)**.
- Arquivos editados no Windows (quebra de linha CRLF) funcionam normalmente.

### Arquivo em outro local

```bash
sudo bash zabbix-server.bash --env /root/zabbix.env
```

### Prioridade dos valores

```
variável na linha de comando  >  arquivo .env  >  valor padrão
```

Exemplo: sobrescrever apenas o nome exibido, mantendo o resto do `.env`:

```bash
sudo ZBX_NAME=zabbix-teste bash zabbix-server.bash
```

---

## O que o script faz

1. Verifica se está rodando como root e em Ubuntu
2. Carrega os parâmetros do `.env`
3. Gera os locales `en_US.UTF-8` e `pt_BR.UTF-8` e ajusta o fuso horário
4. Adiciona o repositório oficial do Zabbix 7.0
   - se ainda não houver pacote específico para o Ubuntu 26.04, usa o do 24.04 e avisa
5. Instala PostgreSQL, Apache, PHP-FPM, Zabbix Server, Frontend e Agent 2
6. Cria o usuário e o banco no PostgreSQL e importa o schema inicial
7. Configura o `zabbix_server.conf`
8. Configura o Apache (`proxy`, `proxy_fcgi`) e o PHP-FPM (fuso horário, limites de memória e tempo)
9. Cria o `zabbix.conf.php` — **o assistente de instalação web é pulado**
10. Libera as portas no UFW (somente se ele estiver ativo)
11. Inicia os serviços e mostra o status de cada um

Todo o processo é registrado em `/var/log/zabbix_install_<data>_<hora>.log`.

---

## Após a instalação

**Acesso ao frontend**

```
http://IP-DO-SERVIDOR/zabbix
```

| Usuário | Senha    |
|---------|----------|
| `Admin` | `zabbix` |

> ⚠️ **Troque a senha do Admin imediatamente** no primeiro acesso: *User settings → Profile → Change password*.

**Portas utilizadas**

| Porta | Uso                                             |
|-------|-------------------------------------------------|
| 80    | Frontend web (HTTP)                             |
| 443   | Frontend web (HTTPS, se configurado)            |
| 10050 | Zabbix Agent (o server consulta os agentes)     |
| 10051 | Zabbix Server (agentes ativos e proxies enviam dados) |

**Verificar os serviços**

```bash
systemctl status zabbix-server zabbix-agent2 apache2 postgresql
```

---

## Executar novamente

O script pode ser executado mais de uma vez no mesmo servidor:

- O banco **não** é recriado e o schema **não** é reimportado se já existirem.
- A senha do usuário do banco e o `zabbix_server.conf` são atualizados.
- O arquivo do frontend `/etc/zabbix/web/zabbix.conf.php` **é mantido** se já existir.

> ⚠️ Se você **mudar a senha** no `.env` e rodar de novo, o frontend continuará com a senha antiga e exibirá erro de conexão com o banco. Nesse caso, edite a senha em `/etc/zabbix/web/zabbix.conf.php` ou faça uma [remoção completa](#remoção-completa) antes de reinstalar.

---

## Remoção completa

Para testar a instalação do zero:

```bash
sudo bash remove.bash
```

O script pede que você digite `REMOVER` para confirmar. Para pular a confirmação:

```bash
sudo bash remove.bash -y
```

> 🛑 **ATENÇÃO:** a remoção apaga o **PostgreSQL inteiro (com TODOS os bancos)**, o **Apache** e o **PHP** do servidor — não apenas o que foi usado pelo Zabbix. **Use somente em servidores de teste dedicados.**

---

## Solução de problemas

**Consultar o log da instalação**

```bash
ls -t /var/log/zabbix_install_*.log | head -1 | xargs less
```

**Um serviço ficou inativo**

```bash
journalctl -u zabbix-server -n 50
tail -n 50 /var/log/zabbix/zabbix_server.log
```

**Apache não inicia**

Confirme que os módulos do PHP-FPM estão ativos e teste a configuração:

```bash
sudo a2enmod proxy proxy_fcgi setenvif
sudo apache2ctl configtest
sudo systemctl restart apache2
```

**Aviso sobre versão do PostgreSQL**

O Zabbix 7.0 suporta oficialmente o PostgreSQL até a versão 17. Se o Ubuntu instalar uma versão mais nova, o script habilita `AllowUnsupportedDBVersions=1` para que o Zabbix Server consiga iniciar. Funciona, mas **não é uma combinação oficialmente suportada**. Para produção, prefira instalar o PostgreSQL 16 ou 17 pelo [repositório oficial do PostgreSQL (PGDG)](https://www.postgresql.org/download/linux/ubuntu/).

**Frontend mostra erro de conexão com o banco**

A senha em `/etc/zabbix/web/zabbix.conf.php` não confere com a do banco. Veja [Executar novamente](#executar-novamente).

**O script pediu a senha mesmo com o `.env`**

O `.env` não está na mesma pasta do script, ou o nome do arquivo está diferente. Confira com:

```bash
ls -la
```

---

## Segurança

- **Nunca envie o `.env` para o repositório.** Ele já está no `.gitignore`; envie apenas o `.env.example`.
- Mantenha o `.env` com permissão `600` (`chmod 600 .env`).
- Troque a senha padrão do usuário `Admin` logo após a instalação.
- Se o frontend for acessado fora da rede local, configure **HTTPS** no Apache.