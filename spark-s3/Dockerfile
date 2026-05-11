FROM docker.io/library/spark:4.0.2
USER root
ADD https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.4.1/hadoop-aws-3.4.1.jar /opt/spark/jars/
ADD https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.12.780/aws-java-sdk-bundle-1.12.780.jar /opt/spark/jars/
ADD https://repo1.maven.org/maven2/software/amazon/awssdk/bundle/2.29.51/bundle-2.29.51.jar /opt/spark/jars/
RUN chmod 644 /opt/spark/jars/hadoop-aws-3.4.1.jar /opt/spark/jars/aws-java-sdk-bundle-1.12.780.jar /opt/spark/jars/bundle-2.29.51.jar
USER spark
