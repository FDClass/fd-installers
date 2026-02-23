#!/usr/bin/env bash
# garante bash mesmo se alguém rodar com sh
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -Eeuo pipefail

# =========================
# Instalador Minimalista (Swarm) - Docker + Traefik + Portainer
# 1 pergunta: domínio do Portainer
# =========================

# Padrões do Fred (fixos)
NETWORK_NAME="fdnet"
LE_EMAIL="derfmusico@gmail.com"

# Versões (conservadoras)
TRAEFIK_IMAGE="traefik:v2.11.2"
PORTAINER_IMAGE="portainer/portainer-ce:2.21.4"
PORTAINER_AGENT_IMAGE="portainer/agent:2.21.4"

STACK_DIR="/opt/stacks"
TRAEFIK_STACK="traefik"
PORTAINER_STACK="portainer"

log()  { echo -e "\n✅ $*\n"; }
warn() { echo -e "\n⚠️  $*\n"; }
die()  { echo -e "\n❌ $*\n"; exit 1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Execute como root: sudo bash $0"
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

install_docker_ubuntu() {
  log "Docker não encontrado. Instalando Docker Engine + Compose plugin (oficial) no Ubuntu..."

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl start docker

  log "Docker instalado com sucesso."
}

ensure_docker() {
  if ! cmd_exists docker; then
    # valida OS (mantendo simples: Ubuntu)
    if [[ -f /etc/os-release ]]; then
      . /etc/os-release
      if [[ "${ID}" == "ubuntu" ]]; then
        install_docker_ubuntu
      else
        die "Este script está preparado para Ubuntu. Detectado: ${ID}. Me peça que eu adapto."
      fi
    else
      die "Não consegui detectar o sistema (sem /etc/os-release)."
    fi
  else
    log "Docker já está instalado."
  fi

  # sanity check
  docker info >/dev/null 2>&1 || die "Docker instalado, mas não está respondendo. Verifique: systemctl status docker"
}

ensure_swarm() {
  log "Checando estado do Swarm"
  local swarm_state
  swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"

  if [[ "${swarm_state}" != "active" ]]; then
    warn "Swarm não está ativo. Inicializando Swarm..."

    # tenta iniciar Swarm com advertise addr automaticamente (1 nó)
    docker swarm init >/dev/null 2>&1 || {
      warn "Falhou swarm init padrão. Tentando com advertise-addr do IPv4..."
      local ip
      ip="$(hostname -I | awk '{print $1}')"
      [[ -z "${ip}" ]] && die "Não consegui detectar IP para advertise-addr."
      docker swarm init --advertise-addr "${ip}" >/dev/null
    }

    log "Swarm inicializado."
  else
    log "Swarm já está ativo."
  fi

  # Confirma
  docker info | grep -i "Swarm: active" >/dev/null || die "Swarm não ficou ativo. Algo deu errado."
}

ensure_network() {
  log "Garantindo rede overlay '${NETWORK_NAME}'"
  if ! docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
    docker network create --driver overlay --attachable "${NETWORK_NAME}" >/dev/null
    log "Rede ${NETWORK_NAME} criada."
  else
    log "Rede ${NETWORK_NAME} já existe."
  fi
}

write_stacks() {
  log "Criando estrutura de stacks em ${STACK_DIR}"
  mkdir -p "${STACK_DIR}/${TRAEFIK_STACK}"
  mkdir -p "${STACK_DIR}/${PORTAINER_STACK}"

  log "Gerando stack do Traefik (Swarm)"
  cat > "${STACK_DIR}/${TRAEFIK_STACK}/docker-compose.yml" <<YAML
version: "3.8"

services:
  traefik:
    image: ${TRAEFIK_IMAGE}
    command:
      - "--api.dashboard=true"
      - "--api.insecure=false"
      - "--providers.docker=true"
      - "--providers.docker.swarmMode=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.letsencrypt.acme.email=${LE_EMAIL}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
    ports:
      - target: 80
        published: 80
        protocol: tcp
        mode: host
      - target: 443
        published: 443
        protocol: tcp
        mode: host
    volumes:
      - traefik_letsencrypt:/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - ${NETWORK_NAME}
    deploy:
      placement:
        constraints:
          - node.role == manager
      replicas: 1

networks:
  ${NETWORK_NAME}:
    external: true

volumes:
  traefik_letsencrypt:
YAML

  log "Gerando stack do Portainer (CE + Agent)"
  cat > "${STACK_DIR}/${PORTAINER_STACK}/docker-compose.yml" <<YAML
version: "3.8"

services:
  agent:
    image: ${PORTAINER_AGENT_IMAGE}
    environment:
      AGENT_CLUSTER_ADDR: tasks.agent
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/lib/docker/volumes:/var/lib/docker/volumes
    networks:
      - ${NETWORK_NAME}
    deploy:
      mode: global
      placement:
        constraints:
          - node.platform.os == linux

  portainer:
    image: ${PORTAINER_IMAGE}
    command: -H tcp://tasks.agent:9001 --tlsskipverify
    volumes:
      - portainer_data:/data
    networks:
      - ${NETWORK_NAME}
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.portainer.rule=Host(\`${PORTAINER_DOMAIN}\`)"
        - "traefik.http.routers.portainer.entrypoints=websecure"
        - "traefik.http.routers.portainer.tls=true"
        - "traefik.http.routers.portainer.tls.certresolver=letsencrypt"
        - "traefik.http.services.portainer.loadbalancer.server.port=9000"

networks:
  ${NETWORK_NAME}:
    external: true

volumes:
  portainer_data:
YAML
}

deploy_stacks() {
  log "Deployando stack do Traefik"
  docker stack deploy -c "${STACK_DIR}/${TRAEFIK_STACK}/docker-compose.yml" "${TRAEFIK_STACK}"

  log "Deployando stack do Portainer"
  docker stack deploy -c "${STACK_DIR}/${PORTAINER_STACK}/docker-compose.yml" "${PORTAINER_STACK}"
}

# ===== MAIN =====
need_root

read -r -p "Subdomínio do Portainer (ex: portainer.cliente.com.br): " PORTAINER_DOMAIN
[[ -z "${PORTAINER_DOMAIN}" ]] && die "Você precisa informar o domínio do Portainer."

ensure_docker
ensure_swarm
ensure_network
write_stacks
deploy_stacks

log "Concluído!"
echo "Portainer: https://${PORTAINER_DOMAIN}"
warn "Checklist se o SSL não emitir:"
echo "1) DNS do subdomínio apontando pro IP da VPS"
echo "2) Portas 80 e 443 liberadas (firewall/provedor)"
echo "3) Logs:"

echo "   docker service logs -f traefik_traefik"


