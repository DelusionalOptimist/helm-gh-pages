#!/usr/bin/env bash

# Copyright 2020 Stefan Prodan. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o pipefail

CHARTS_DIR=$1
CHARTS_URL=$2
OWNER=$3
REPOSITORY=$4
BRANCH=$5
TARGET_DIR=$6
HELM_VERSION=$7
LINTING=$8
COMMIT_USERNAME=${9}
COMMIT_EMAIL=${10}
APP_VERSION=${11}
CHART_VERSION=${12}
INDEX_DIR=${13}
ENTERPRISE_URL=${14}
DEPENDENCIES=${15}

CHARTS=()
CHARTS_TMP_DIR=$(mktemp -d)
#REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_URL=""

export GH_PROMPT_DISABLED=true

main() {
  if [[ -n "GH_TOKEN" ]]; then
      echo "Using GH_TOKEN"
      export GH_TOKEN=${GH_TOKEN}
  else
      echo "must specify GH_TOKEN env variable"
      exit 1
  fi

  if [[ -z "$HELM_VERSION" ]]; then
      HELM_VERSION="3.10.0"
  fi

  if [[ -z "$CHARTS_DIR" ]]; then
      CHARTS_DIR="charts"
  fi

  if [[ -z "$OWNER" ]]; then
      OWNER=$(cut -d '/' -f 1 <<< "$GITHUB_REPOSITORY")
  fi

  if [[ -z "$REPOSITORY" ]]; then
      REPOSITORY=$(cut -d '/' -f 2 <<< "$GITHUB_REPOSITORY")
  fi

  if [[ -z "$BRANCH" ]]; then
      BRANCH="gh-pages"
  fi

  if [[ -z "$TARGET_DIR" ]]; then
    TARGET_DIR="."
  fi

  if [[ -z "$CHARTS_URL" ]]; then
      CHARTS_URL="https://${OWNER}.github.io/${REPOSITORY}"
  fi

  if [[ "$TARGET_DIR" != "." && "$TARGET_DIR" != "docs" ]]; then
    CHARTS_URL="${CHARTS_URL}/${TARGET_DIR}"
  fi

  if [[ -z "$REPO_URL" ]]; then
      if [[ -z "$ENTERPRISE_URL" ]]; then
          REPO_URL="https://oauth2:${GH_TOKEN}@github.com/${OWNER}/${REPOSITORY}"
      else
          REPO_URL="https://oauth2:${GH_TOKEN}@${ENTERPRISE_URL}/${REPOSITORY}"
      fi
  fi

  if [[ -z "$COMMIT_USERNAME" ]]; then
      COMMIT_USERNAME="${GITHUB_ACTOR}"
  fi

  if [[ -z "$COMMIT_EMAIL" ]]; then
      COMMIT_EMAIL="${GITHUB_ACTOR}@users.noreply.github.com"
  fi

  if [[ -z "$INDEX_DIR" ]]; then
      INDEX_DIR=${TARGET_DIR}
  fi

  locate
  download
  get_dependencies
  dependencies
  if [[ "$LINTING" != "off" ]]; then
    lint
  fi
  package
  upload
}

locate() {
  for dir in $(find "${CHARTS_DIR}" -type d -mindepth 1 -maxdepth 1); do
    if [[ -f "${dir}/Chart.yaml" ]]; then
      CHARTS+=("${dir}")
      echo "Found chart directory ${dir}"
    else
      echo "Ignoring non-chart directory ${dir}"
    fi
  done
}

download() {
  tmpDir=$(mktemp -d)

  pushd $tmpDir >& /dev/null

  curl -sSL https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz | tar xz
  cp linux-amd64/helm /usr/local/bin/helm

  popd >& /dev/null
  rm -rf $tmpDir
}

get_dependencies() {
  IFS=';' read -ra dependency <<< "$DEPENDENCIES"
  for repos in ${dependency[@]}; do
    result=$( echo $repos|awk -F',' '{print NF}' )
    if [[ $result -gt 2 ]]; then
      name=$(cut -f 1 -d, <<< "$repos")
      username=$(cut -f 2 -d, <<< "$repos")
      password=$(cut -f 3 -d, <<< "$repos")
      url=$(cut -f 4 -d, <<< "$repos")
      helm repo add ${name} --username ${username} --password ${password} ${url}
    else
      name=$(cut -f 1 -d, <<< "$repos")
      url=$(cut -f 2 -d, <<< "$repos")
      helm repo add ${name} ${url}
    fi
  done
}

dependencies() {
  for chart in ${CHARTS[@]}; do
    helm dependency update "${chart}"
  done
}

lint() {
  helm lint ${CHARTS[*]}
}

package() {
  if [[ ! -z "$APP_VERSION" ]]; then
      APP_VERSION_CMD=" --app-version $APP_VERSION"
  fi

  if [[ ! -z "$CHART_VERSION" ]]; then
      CHART_VERSION_CMD=" --version $CHART_VERSION"
  fi

  helm package ${CHARTS[*]} --destination ${CHARTS_TMP_DIR} $APP_VERSION_CMD$CHART_VERSION_CMD
}

upload() {
  tmpDir=$(mktemp -d)
  pushd $tmpDir >& /dev/null

  gh repo clone "${OWNER}/${REPOSITORY}"
  cd ${REPOSITORY}
  git config user.name "${COMMIT_USERNAME}"
  git config user.email "${COMMIT_EMAIL}"
  git remote set-url origin ${REPO_URL}
  git checkout ${BRANCH}

  charts=$(cd ${CHARTS_TMP_DIR} && ls *.tgz | xargs)

  mkdir -p ${INDEX_DIR}
  mkdir -p ${TARGET_DIR}

  if [[ -f "${INDEX_DIR}/index.yaml" ]]; then
    echo "Found index, merging changes"
    helm repo index ${CHARTS_TMP_DIR} --url ${CHARTS_URL} --merge "${INDEX_DIR}/index.yaml"
    mv -f ${CHARTS_TMP_DIR}/*.tgz ${TARGET_DIR}
    mv -f ${CHARTS_TMP_DIR}/index.yaml ${INDEX_DIR}/index.yaml
  else
    echo "No index found, generating a new one"
    helm repo index ${CHARTS_TMP_DIR} --url ${CHARTS_URL}
    mv -f ${CHARTS_TMP_DIR}/*.tgz ${TARGET_DIR}
    mv -f ${CHARTS_TMP_DIR}/index.yaml ${INDEX_DIR}
  fi

  git add ${TARGET_DIR}
  git add ${INDEX_DIR}/index.yaml

  git commit -m "Publish $charts"
  git push origin ${BRANCH}

  popd >& /dev/null
  rm -rf $tmpDir
}

main
