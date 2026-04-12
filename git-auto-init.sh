#!/bin/sh

if [ -z "$GITHUB_TOKEN" ] || [ -z "$GITHUB_USER" ]; then
  echo "❗ Ошибка: переменные GITHUB_TOKEN или GITHUB_USER не установлены!"
  exit 1
fi

echo "Введите название репозитория:"
read repository

git init

git config --global user.name $GITHUB_USER
git config --global user.email $GITHUB_EMAIL

git add .

git commit -m "init: start project \"$repository\" ($(LANG=en_EN date +'%a, %b %d, %Y %r'))"

curl -u $GITHUB_USER:$GITHUB_TOKEN \
  https://api.github.com/user/repos \
  -d "{\"name\":\"$repository\"}"

git branch -M main

git remote add origin https://github.com/$GITHUB_USER/$repository.git

git push -u origin main