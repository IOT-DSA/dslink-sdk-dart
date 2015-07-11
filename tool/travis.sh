#!/usr/bin/env bash
set -e

./tool/analyze.sh
./tool/test.sh
if [ "${TRAVIS_DART_VERSION}" == "stable" ] && [ "${TRAVIS_PULL_REQUEST}" == "false" ]
then
  if [ ! -d ${HOME}/.ssh ]
  then
    mkdir ${HOME}/.ssh
  fi

  openssl aes-256-cbc -K $encrypted_afe27f9b0c58_key -iv $encrypted_afe27f9b0c58_iv -in tool/id_rsa.enc -out ${HOME}/.ssh/id_rsa -d
  chmod 600 ${HOME}/.ssh/id_rsa
  echo -e "Host github.com\n\tStrictHostKeyChecking no\n" >> ${HOME}/.ssh/config
  ./tool/docs.sh --upload
fi
