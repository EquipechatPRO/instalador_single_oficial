#!/bin/bash

GREEN='\033[1;32m'
BLUE='\033[1;34m'
WHITE='\033[1;37m'
RED='\033[1;31m'
YELLOW='\033[1;33m'

# Variaveis Padrão
ARCH=$(uname -m)
UBUNTU_VERSION=$(lsb_release -sr)
ARQUIVO_VARIAVEIS="VARIAVEIS_INSTALACAO"
ip_atual=$(curl -s http://checkip.amazonaws.com)
default_apioficial_port=6000

if [ "$EUID" -ne 0 ]; then
    echo
    printf "${WHITE} >> Este script precisa ser executado como root ${RED}ou com privilégios de superusuário${WHITE}.\n"
    echo
    sleep 2
    exit 1
fi

# Função para manipular erros
trata_erro() {
    printf "${RED}Erro encontrado na etapa $1. Encerrando o script.${WHITE}\n"
    exit 1
}

# Banner
banner() {
    clear
    printf "${BLUE}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    INSTALADOR API OFICIAL                    ║"
    echo "║                                                              ║"
    echo "║                    MultiFlow System                          ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    printf "${WHITE}"
    echo
}

reparo_nginx_critico() {
    banner
    printf "${YELLOW} >> Executando Reparo Crítico de Configuração do Nginx...${WHITE}\n"
    sudo rm -f /etc/nginx/sites-enabled/-oficial
    sudo rm -f /etc/nginx/sites-available/-oficial
    sudo sed -i '/include \/etc\/nginx\/sites-enabled\/-oficial;/d' /etc/nginx/nginx.conf
    
    printf "${GREEN} >> Reparo concluído. Testando a configuração do Nginx...${WHITE}\n"
    sudo nginx -t
    if [ $? -ne 0 ]; then
        printf "${RED} >> ERRO: O Nginx ainda não passou no teste de configuração.${WHITE}\n"
        exit 1
    fi
    printf "${GREEN} >> Nginx pronto. Continuando...${WHITE}\n"
    sleep 2
}

# --- FUNÇÃO EDITADA PARA PEGAR DADOS DO BACKEND ---
carregar_variaveis() {
    if [ -f "$ARQUIVO_VARIAVEIS" ]; then
        source "$ARQUIVO_VARIAVEIS"
    else
        printf "${YELLOW} >> Arquivo $ARQUIVO_VARIAVEIS não encontrado. Buscando dados no backend...${WHITE}\n"
        
        # Define os padrões conforme sua estrutura
        empresa="multiflow"
        nome_titulo="MultiFlow"
        backend_env_path="/home/deploy/${empresa}/backend/.env"

        if [ -f "${backend_env_path}" ]; then
            # Extrai as variáveis do .env do backend
            # Adaptado para pegar DB_PASS ou POSTGRES_PASSWORD
            senha_deploy=$(grep "^DB_PASS=" "${backend_env_path}" | cut -d '=' -f2- | tr -d '\r')
            [ -z "$senha_deploy" ] && senha_deploy=$(grep "^POSTGRES_PASSWORD=" "${backend_env_path}" | cut -d '=' -f2- | tr -d '\r')
            
            # Pega o email para o SSL
            email_deploy=$(grep "^USER_EMAIL=" "${backend_env_path}" | cut -d '=' -f2- | tr -d '\r')
            
            # Cria o arquivo para evitar erros em passos futuros que leem este arquivo
            echo "empresa=${empresa}" > "$ARQUIVO_VARIAVEIS"
            echo "nome_titulo=${nome_titulo}" >> "$ARQUIVO_VARIAVEIS"
            echo "senha_deploy=${senha_deploy}" >> "$ARQUIVO_VARIAVEIS"
            echo "email_deploy=${email_deploy}" >> "$ARQUIVO_VARIAVEIS"
            
            printf "${GREEN} >> Dados carregados com sucesso de: ${backend_env_path}${WHITE}\n"
            sleep 2
        else
            printf "${RED} >> ERRO: Arquivo .env não encontrado em ${backend_env_path}${WHITE}\n"
            exit 1
        fi
    fi
}

carregar_subdominio_backend() {
    if [ -z "${subdominio_backend}" ]; then
        local backend_env_path="/home/deploy/${empresa}/backend/.env"
        if [ -f "${backend_env_path}" ]; then
            local subdominio_backend_full=$(grep "^BACKEND_URL=" "${backend_env_path}" 2>/dev/null | cut -d '=' -f2- | tr -d '\r')
            subdominio_backend=$(echo "${subdominio_backend_full}" | sed 's|https://||g' | sed 's|http://||g' | cut -d'/' -f1)
            echo "subdominio_backend=${subdominio_backend}" >>$ARQUIVO_VARIAVEIS
        else
            printf "${RED} >> ERRO: Não foi possível encontrar o .env do backend.${WHITE}\n"
            exit 1
        fi
    fi
}

solicitar_dados_apioficial() {
    local temp_subdominio_oficial
    banner
    printf "${WHITE} >> Insira o subdomínio da API Oficial (Ex: api.seusistema.com.br): \n"
    read -p "> " temp_subdominio_oficial
    subdominio_oficial=$(echo "${temp_subdominio_oficial}" | sed 's|https://||g' | sed 's|http://||g' | cut -d'/' -f1)
    echo "subdominio_oficial=${subdominio_oficial}" >>$ARQUIVO_VARIAVEIS
}

verificar_dns_apioficial() {
    banner
    printf "${WHITE} >> Verificando o DNS do subdomínio: ${subdominio_oficial}...\n"
    if ! command -v dig &> /dev/null; then
        sudo apt-get update >/dev/null 2>&1
        sudo apt-get install dnsutils -y >/dev/null 2>&1
    fi
    local resolved_ip=$(dig +short ${subdominio_oficial} @8.8.8.8)
    if [[ "${resolved_ip}" != "${ip_atual}"* ]] || [ -z "${resolved_ip}" ]; then
        printf "${RED} >> ERRO: DNS não aponta para este IP (${ip_atual}).${WHITE}\n"
        sleep 5
        exit 1
    fi
}

configurar_nginx_apioficial() {
    banner
    printf "${WHITE} >> Configurando Nginx e SSL...\n"
    local sites_available_path="/etc/nginx/sites-available/${empresa}-oficial"
    local sites_enabled_link="/etc/nginx/sites-enabled/${empresa}-oficial"

    sudo rm -f "${sites_enabled_link}"
    sudo rm -f "${sites_available_path}"

    sudo bash -c "cat > ${sites_available_path} << 'END'
upstream oficial {
    server 127.0.0.1:${default_apioficial_port};
    keepalive 32;
}
server {
    server_name ${subdominio_oficial};
    location / {
        proxy_pass http://oficial;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_cache_bypass \$http_upgrade;
    }
}
END"
    sudo ln -sf ${sites_available_path} ${sites_enabled_link}
    sudo systemctl reload nginx

    sudo certbot -m "${email_deploy}" --nginx --agree-tos -n -d "${subdominio_oficial}"
}

criar_banco_apioficial() {
    banner
    printf "${WHITE} >> Criando banco 'oficialseparado'...\n"
    sudo -u postgres psql -c "CREATE DATABASE oficialseparado WITH OWNER ${empresa};"
}

configurar_env_apioficial() {
    banner
    printf "${WHITE} >> Configurando .env da API Oficial...\n"
    local backend_env_path="/home/deploy/${empresa}/backend/.env"
    local jwt_refresh_secret_backend=$(grep "^JWT_REFRESH_SECRET=" "${backend_env_path}" | cut -d '=' -f2- | tr -d '\r')
    local backend_url_full=$(grep "^BACKEND_URL=" "${backend_env_path}" | cut -d '=' -f2- | tr -d '\r')
    
    local api_oficial_dir="/home/deploy/${empresa}/api_oficial"
    mkdir -p "${api_oficial_dir}"
    
    sudo -u deploy bash -c "cat > ${api_oficial_dir}/.env <<EOF
DATABASE_LINK=postgresql://${empresa}:${senha_deploy}@localhost:5432/oficialseparado?schema=public
DATABASE_URL=localhost
DATABASE_PORT=5432
DATABASE_USER=${empresa}
DATABASE_PASSWORD=${senha_deploy}
DATABASE_NAME=oficialseparado
TOKEN_ADMIN=adminpro
URL_BACKEND_MULT100=${backend_url_full}
JWT_REFRESH_SECRET=${jwt_refresh_secret_backend}
REDIS_URI=redis://:${senha_deploy}@127.0.0.1:6379
PORT=${default_apioficial_port}
URL_API_OFICIAL=${subdominio_oficial}
NAME_ADMIN=SetupAutomatizado
EMAIL_ADMIN=admin@multi100.com.br
PASSWORD_ADMIN=adminpro
EOF"
}

instalar_apioficial() {
    banner
    printf "${WHITE} >> Rodando npm install e build...\n"
    local api_oficial_dir="/home/deploy/${empresa}/api_oficial"
    sudo su - deploy <<INSTALL_API
    cd ${api_oficial_dir}
    export PATH=/usr/local/n/versions/node/20.19.4/bin:/usr/bin:/usr/local/bin:\$PATH
    npm install --force
    npx prisma generate
    npm run build
    npx prisma migrate deploy
    pm2 start dist/main.js --name=api_oficial
    pm2 save
INSTALL_API
}

atualizar_env_backend() {
    banner
    printf "${WHITE} >> Vinculando API Oficial ao Backend...\n"
    local backend_env_path="/home/deploy/${empresa}/backend/.env"
    sudo sed -i 's|^USE_WHATSAPP_OFICIAL=.*|USE_WHATSAPP_OFICIAL=true|' "${backend_env_path}"
    if grep -q "^URL_API_OFICIAL=" "${backend_env_path}"; then
        sudo sed -i "s|^URL_API_OFICIAL=.*|URL_API_OFICIAL=https://${subdominio_oficial}|" "${backend_env_path}"
    else
        echo "URL_API_OFICIAL=https://${subdominio_oficial}" | sudo tee -a "${backend_env_path}"
    fi
    sudo su - deploy -c "pm2 reload ${empresa}-backend"
}

reiniciar_servicos() {
    sudo systemctl restart nginx
}

main() {
    reparo_nginx_critico
    carregar_variaveis
    carregar_subdominio_backend
    solicitar_dados_apioficial
    verificar_dns_apioficial
    configurar_nginx_apioficial 
    criar_banco_apioficial
    configurar_env_apioficial
    instalar_apioficial
    atualizar_env_backend
    reiniciar_servicos
    
    banner
    printf "${GREEN} >> Instalação concluída! https://${subdominio_oficial}${WHITE}\n"
}

main
