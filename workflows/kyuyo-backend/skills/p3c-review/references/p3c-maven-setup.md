# P3C Maven Setup

Use this setup when repository `pom.xml` does not already include Alibaba P3C PMD rules.

## Minimal profile snippet

Add the following profile to root `pom.xml`:

```xml
<profiles>
    <profile>
        <id>p3c-review</id>
        <build>
            <plugins>
                <plugin>
                    <groupId>org.apache.maven.plugins</groupId>
                    <artifactId>maven-pmd-plugin</artifactId>
                    <version>3.21.2</version>
                    <configuration>
                        <failOnViolation>true</failOnViolation>
                        <printFailingErrors>true</printFailingErrors>
                        <rulesets>
                            <ruleset>category/java/ali-comment.xml</ruleset>
                            <ruleset>category/java/ali-concurrent.xml</ruleset>
                            <ruleset>category/java/ali-constant.xml</ruleset>
                            <ruleset>category/java/ali-exception.xml</ruleset>
                            <ruleset>category/java/ali-flowcontrol.xml</ruleset>
                            <ruleset>category/java/ali-naming.xml</ruleset>
                            <ruleset>category/java/ali-ooh.xml</ruleset>
                            <ruleset>category/java/ali-orm.xml</ruleset>
                            <ruleset>category/java/ali-set.xml</ruleset>
                            <ruleset>category/java/ali-spring.xml</ruleset>
                            <ruleset>category/java/ali-unittest.xml</ruleset>
                            <ruleset>category/java/ali-other.xml</ruleset>
                        </rulesets>
                    </configuration>
                    <dependencies>
                        <dependency>
                            <groupId>com.alibaba.p3c</groupId>
                            <artifactId>p3c-pmd</artifactId>
                            <version>2.1.1</version>
                        </dependency>
                    </dependencies>
                </plugin>
            </plugins>
        </build>
    </profile>
</profiles>
```

Run:

```bash
mvn -Pp3c-review -DskipTests pmd:pmd pmd:check
```

## Review guidance

- Treat `Blocker` or build-breaking findings as merge blockers.
- Prioritize concurrency, exception, and SQL-related findings.
- For noisy style-only items, group by rule and suggest codemod patterns.
