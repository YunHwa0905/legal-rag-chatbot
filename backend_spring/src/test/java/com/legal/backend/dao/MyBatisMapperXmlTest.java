package com.legal.backend.dao;

import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;
import org.xml.sax.InputSource;

import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;
import java.io.File;
import java.io.FileReader;
import java.util.Arrays;
import java.util.List;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;

/**
 * C1 후속 — 이 프로젝트엔 Spring 컨텍스트 테스트가 없어서(의도된 제약) mvn test가
 * 지금까지 mybatis/*.xml을 한 번도 파싱한 적이 없었다. 그래서 ChatSessionSummaryMapper.xml의
 * 이스케이프 안 된 &lt;(잘못된 XML)가 12번의 개별 리뷰를 다 통과하고도 SqlSessionFactory
 * 생성 시점(= 앱 기동 시점)까지 살아남았다. 이 테스트는 그 클래스의 결함을
 * mvn test 한 번으로 잡아내는 값싼 상시 가드다 — DTD는 검증하지 않는다(오프라인에서
 * mybatis.org를 fetch하지 않기 위함), 잘 정돈된(well-formed) XML인지만 확인한다.
 */
class MyBatisMapperXmlTest {

    private static final File MAPPER_DIR = new File("src/main/resources/mybatis");

    @TestFactory
    Stream<DynamicTest> 모든_매퍼_XML은_well_formed다() {
        File[] files = MAPPER_DIR.listFiles((dir, name) -> name.endsWith(".xml"));
        List<File> mappers = files != null ? Arrays.asList(files) : List.of();

        return mappers.stream().map(file -> DynamicTest.dynamicTest(file.getName(), () ->
                assertDoesNotThrow(() -> parseWithoutExternalDtd(file),
                        file.getName() + " 이 well-formed XML이 아닙니다 — MyBatis SqlSessionFactory 생성이 실패해 " +
                                "Spring 컨텍스트 전체가 기동하지 못합니다.")
        ));
    }

    @TestFactory
    Stream<DynamicTest> 매퍼_디렉터리에_최소_한_개_이상의_XML이_있다() {
        File[] files = MAPPER_DIR.listFiles((dir, name) -> name.endsWith(".xml"));
        return Stream.of(DynamicTest.dynamicTest("mapper 디렉터리 비어있지 않음", () ->
                assertDoesNotThrow(() -> {
                    if (files == null || files.length == 0) {
                        throw new IllegalStateException(
                                MAPPER_DIR.getAbsolutePath() + " 에서 매퍼 XML을 찾지 못했습니다 — " +
                                        "테스트가 잘못된 작업 디렉터리에서 돌고 있을 수 있습니다.");
                    }
                })
        ));
    }

    private void parseWithoutExternalDtd(File file) throws Exception {
        DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
        // MyBatis DTD(mybatis.org)를 매 테스트마다 네트워크로 받아오지 않는다 —
        // well-formedness만 확인하면 되고, DTD 검증은 목적이 아니다.
        factory.setValidating(false);
        factory.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false);
        DocumentBuilder builder = factory.newDocumentBuilder();
        try (FileReader reader = new FileReader(file)) {
            builder.parse(new InputSource(reader));
        }
    }
}
