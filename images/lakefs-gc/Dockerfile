# syntax=docker/dockerfile:1.7
# lakeFS garbage collection (Community): Spark 3.5 (Hadoop 3.3.4) with the lakeFS Spark client and the S3A connector
# baked in, every jar checked by sha256 at build time. Baked, not downloaded at run time, so the pod that holds the
# lakeFS and SeaweedFS keys never needs internet access (ADR-015). Built and scanned by .github/workflows/images.yml.
FROM apache/spark:3.5.9-scala2.12-java17-ubuntu@sha256:5eb9236efcfee5e447d6fe30cf8376e2ca4f79671350ed89f990f9b3e84b954c

# Parts of Spark the GC never uses (Hive's embedded metastore, cluster coordination): removed, with their CVEs.
USER root
RUN rm -f /opt/spark/jars/derby-*.jar /opt/spark/jars/zookeeper-*.jar

# S3A for Hadoop 3.3.4 (the Hadoop of this Spark build); checksums match Maven Central's .sha1 files
ADD --checksum=sha256:53f9ae03c681a30a50aa17524bd9790ab596b28481858e54efd989a826ed3a4a --chmod=0644 \
    https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.3.4/hadoop-aws-3.3.4.jar /opt/spark/jars/
ADD --checksum=sha256:873fe7cf495126619997bec21c44de5d992544aea7e632fdc77adb1a0915bae5 --chmod=0644 \
    https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.12.262/aws-java-sdk-bundle-1.12.262.jar /opt/spark/jars/
# lakeFS Spark client 0.22.0 (Scala 2.12, Spark 3.x). Treeverse publishes no checksum: this is the sha256 of the copy
# downloaded and checked on 2026-11-15; a different file fails the build.
ADD --checksum=sha256:384d4b4dfd4f5d2465b4d0598b1a3be87267c80f202ff2292b953700013f9952 --chmod=0644 \
    https://treeverse-clients-us-east.s3.amazonaws.com/lakefs-spark-client/0.22.0/lakefs-spark-client_2.12-assembly-0.22.0.jar /opt/gc/lakefs-gc.jar

USER 185
