#!/bin/sh
# noredist 빌드용 non-OSS JAR → ~/.m2 등록 (namuVIRT 4.22 최소 10종).
# 이 디렉터리의 JAR 는 레포에 커밋되어 있어야 함 (vendor/cloudstack-nonoss/).

set -e

# JAR 파일 존재 확인 후 mvn install:install-file 실행.
install_jar() {
  local file="$1"
  shift
  [ -s "${file}" ] || {
    echo "missing required JAR: ${file}" >&2
    exit 1
  }
  mvn install:install-file -Dfile="${file}" "$@"
}

# VMware vSphere 8.0 (cs.vmware.api.version)
install_jar vim25_80.jar \
  -DgroupId=com.cloud.com.vmware -DartifactId=vmware-vim25 -Dversion=8.0 -Dpackaging=jar
install_jar pbm_80.jar \
  -DgroupId=com.cloud.com.vmware -DartifactId=vmware-pbm -Dversion=8.0 -Dpackaging=jar

# NSX 4.1 + vAPI 2.40 (plugins/network-elements/nsx)
install_jar nsx-java-sdk-4.1.0.2.0.jar \
  -DgroupId=com.vmware -DartifactId=nsx-java-sdk -Dversion=4.1.0.2.0 -Dpackaging=jar
install_jar nsx-gpm-java-sdk-4.1.0.2.0.jar \
  -DgroupId=com.vmware -DartifactId=nsx-gpm-java-sdk -Dversion=4.1.0.2.0 -Dpackaging=jar
install_jar nsx-policy-java-sdk-4.1.0.2.0.jar \
  -DgroupId=com.vmware -DartifactId=nsx-policy-java-sdk -Dversion=4.1.0.2.0 -Dpackaging=jar
install_jar vapi-authentication-2.40.0.jar \
  -DgroupId=com.vmware.vapi -DartifactId=vapi-authentication -Dversion=2.40.0 -Dpackaging=jar
install_jar vapi-runtime-2.40.0.jar \
  -DgroupId=com.vmware.vapi -DartifactId=vapi-runtime -Dversion=2.40.0 -Dpackaging=jar

# Netris, Contrail, Tungsten network plugins
install_jar netris-java-sdk-1.0.0.jar \
  -DgroupId=io.netris -DartifactId=netris-java-sdk -Dversion=1.0.0 -Dpackaging=jar
install_jar juniper-contrail-api-1.0-SNAPSHOT.jar \
  -DgroupId=net.juniper.contrail -DartifactId=juniper-contrail-api -Dversion=1.0-SNAPSHOT -Dpackaging=jar
install_jar juniper-tungsten-api-2.0.jar \
  -DgroupId=net.juniper.tungsten -DartifactId=juniper-tungsten-api -Dversion=2.0 -Dpackaging=jar

echo "non-OSS JARs installed to ~/.m2"
