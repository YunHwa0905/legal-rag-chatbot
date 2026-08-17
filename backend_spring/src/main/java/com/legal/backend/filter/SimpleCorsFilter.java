package com.legal.backend.filter;

import javax.servlet.*;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;

/**
 * Spring Legacy + Tomcat 환경에서 CORS 처리는
 * servlet-context.xml 의 mvc:cors 만으로는 OPTIONS preflight 를
 * DispatcherServlet 이전에 처리하지 못하는 경우가 있습니다.
 *
 * 따라서 CORS 는 이 Filter 한 곳에서만 처리합니다.
 * servlet-context.xml 의 <mvc:cors> 블록은 제거했습니다.
 */
public class SimpleCorsFilter implements Filter {

    /** 로컬 개발에서 프론트를 따로 띄울 때의 기본 허용 출처 */
    private static final String DEFAULT_ORIGIN = "http://localhost:3000";

    /**
     * 허용 출처는 CORS_ALLOWED_ORIGIN 환경변수로 결정합니다.
     *
     *  - 환경변수 없음   → DEFAULT_ORIGIN (로컬 개발 동작 유지)
     *  - 환경변수 빈 값  → CORS 헤더를 아예 내리지 않음
     *  - 환경변수 값 있음 → 그 출처만 허용
     *
     * 배포 환경에서는 리버스 프록시가 프론트와 API 를 같은 오리진으로 묶으므로
     * CORS 가 필요 없습니다. compose 에서 빈 값을 넘겨 헤더를 끕니다.
     */
    private String allowedOrigin;

    @Override
    public void init(FilterConfig filterConfig) {
        String configured = System.getenv("CORS_ALLOWED_ORIGIN");
        this.allowedOrigin = (configured == null) ? DEFAULT_ORIGIN : configured.trim();
    }

    @Override
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException {

        HttpServletRequest  req = (HttpServletRequest)  request;
        HttpServletResponse res = (HttpServletResponse) response;

        if (!allowedOrigin.isEmpty()) {
            res.setHeader("Access-Control-Allow-Origin",  allowedOrigin);
            res.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
            res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
            res.setHeader("Access-Control-Allow-Credentials", "true");
            res.setHeader("Access-Control-Max-Age", "3600");
        }

        // OPTIONS preflight 는 바로 200 반환 — 뒤에 JwtFilter 등 타지 않도록
        if ("OPTIONS".equalsIgnoreCase(req.getMethod())) {
            res.setStatus(HttpServletResponse.SC_OK);
            return;
        }

        chain.doFilter(request, response);
    }

    @Override public void destroy() {}
}