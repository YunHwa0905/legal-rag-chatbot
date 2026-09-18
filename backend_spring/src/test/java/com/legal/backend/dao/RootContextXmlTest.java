package com.legal.backend.dao;

import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.NodeList;

import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;
import java.io.File;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;

/**
 * MyBatisMapperXmlTest와 같은 이유, 다른 파일. Phase 1의 C1(mybatis/*.xml)에 대한 가드는
 * 있었지만, Redis 빈을 XML로 직접 추가한 이 Task는 WEB-INF/spring/*.xml(빈 배선이 실제로
 * 사는 곳)엔 같은 가드가 없었다 — 오타 하나가 mvn test는 통과하고 ContextLoaderListener
 * 기동 시점에만 터지는, 똑같은 종류의 결함을 다시 만들 수 있는 자리였다.
 *
 * DTD/XSD는 네트워크로 받아오지 않는다(오프라인에서 spring.io를 fetch하지 않기 위함) —
 * well-formedness와, 각 bean의 class="..."가 실제로 존재하는 클래스인지(가장 흔한 오타
 * 종류)만 확인한다. 잘못된 constructor-arg 인덱스나 풀리지 않는 ${...} 플레이스홀더까지는
 * 못 잡는다 — 그건 실제 컨텍스트를 띄워야 잡히고, 이 프로젝트는 의도적으로 Spring 컨텍스트
 * 테스트를 안 쓴다. 그래도 가장 흔한 실수(클래스명 오타)는 20줄로 막는다.
 */
class RootContextXmlTest {

    private static final File SPRING_XML_DIR = new File("src/main/webapp/WEB-INF/spring");

    @TestFactory
    Stream<DynamicTest> 모든_스프링_XML은_well_formed다() {
        List<File> files = xmlFiles();

        return files.stream().map(file -> DynamicTest.dynamicTest(file.getName(), () ->
                assertDoesNotThrow(() -> parse(file),
                        file.getName() + " 이 well-formed XML이 아닙니다 — ContextLoaderListener 기동이 " +
                                "실패해 Spring 컨텍스트 전체가 뜨지 못합니다.")
        ));
    }

    @TestFactory
    Stream<DynamicTest> 모든_빈의_class_속성은_실제_존재하는_클래스다() throws Exception {
        List<File> files = xmlFiles();
        List<DynamicTest> tests = new ArrayList<>();

        for (File file : files) {
            Document doc = parse(file);
            NodeList beans = doc.getElementsByTagName("bean");
            for (int i = 0; i < beans.getLength(); i++) {
                Element bean = (Element) beans.item(i);
                String className = bean.getAttribute("class");
                if (className == null || className.isEmpty()) {
                    continue; // factory-bean 참조 등 class 속성이 없는 빈은 스킵
                }
                String beanId = bean.hasAttribute("id") ? bean.getAttribute("id") : className;
                tests.add(DynamicTest.dynamicTest(file.getName() + " / " + beanId, () ->
                        assertDoesNotThrow(() -> Class.forName(className),
                                file.getName() + "의 빈 '" + beanId + "'이 가리키는 클래스 '" + className +
                                        "'을 찾을 수 없습니다 — 클래스명 오타이거나 의존성이 누락됐을 수 있습니다.")
                ));
            }
        }
        return tests.stream();
    }

    @TestFactory
    Stream<DynamicTest> 디렉터리에_최소_한_개_이상의_XML이_있다() {
        List<File> files = xmlFiles();
        return Stream.of(DynamicTest.dynamicTest("WEB-INF/spring 디렉터리 비어있지 않음", () ->
                assertDoesNotThrow(() -> {
                    if (files.isEmpty()) {
                        throw new IllegalStateException(
                                SPRING_XML_DIR.getAbsolutePath() + " 에서 XML을 찾지 못했습니다 — " +
                                        "테스트가 잘못된 작업 디렉터리에서 돌고 있을 수 있습니다.");
                    }
                })
        ));
    }

    private List<File> xmlFiles() {
        File[] files = SPRING_XML_DIR.listFiles((dir, name) -> name.endsWith(".xml"));
        return files != null ? Arrays.asList(files) : List.of();
    }

    private Document parse(File file) throws Exception {
        DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
        factory.setValidating(false);
        factory.setNamespaceAware(true);
        factory.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false);
        factory.setFeature("http://apache.org/xml/features/validation/schema", false);
        DocumentBuilder builder = factory.newDocumentBuilder();
        // File을 바로 넘긴다 — MyBatisMapperXmlTest와 동일한 이유(플랫폼 기본 인코딩이
        // <?xml ... encoding="UTF-8"?> 선언을 가리지 않게).
        return builder.parse(file);
    }
}
