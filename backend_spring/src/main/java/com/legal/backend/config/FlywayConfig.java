package com.legal.backend.config;

import org.flywaydb.core.Flyway;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import javax.sql.DataSource;

@Configuration
public class FlywayConfig {

    /**
     * initMethod="migrate" — 이 빈이 생성되는 시점(앱 시작)에 자동으로 migrate() 실행.
     * baselineOnMigrate: 이미 users 테이블이 있는(= deploy/init.sql로 만들어진) 기존 DB에도
     * "스키마가 비어있지 않다"는 에러 없이 안전하게 V1부터 적용한다.
     */
    @Bean(initMethod = "migrate")
    public Flyway flyway(DataSource dataSource) {
        return Flyway.configure()
                .dataSource(dataSource)
                .baselineOnMigrate(true)
                .baselineVersion("0")
                .locations("classpath:db/migration")
                .load();
    }
}
