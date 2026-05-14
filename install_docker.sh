#!/bin/bash

echo "1. Оновлення пакетів..."
sudo apt update && sudo apt upgrade -y

echo "2. Встановлення залежностей..."
sudo apt install -y ca-certificates curl gnupg

echo "3. Додавання GPG-ключа Docker..."
sudo install -m 0755 -d /etc/apt/keyrings
# Очищений рядок без зайвих дужок:
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "4. Налаштування репозиторію..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "5. Встановлення Docker..."
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "6. Налаштування прав для користувача $USER..."
sudo usermod -aG docker $USER

echo "Перевірка версій:"
docker --version
docker compose version

echo "Готово! Виконайте 'newgrp docker' або перезайдіть у систему."