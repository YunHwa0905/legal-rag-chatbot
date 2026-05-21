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

    @Override
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException {

        HttpServletRequest  req = (HttpServletRequest)  request;
        HttpServletResponse res = (HttpServletResponse) response;

        // 허용 출처: 프론트 Express 서버
        res.setHeader("Access-Control-Allow-Origin",  "http://localhost:3000");
        res.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
        res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
        res.setHeader("Access-Control-Allow-Credentials", "true");
        res.setHeader("Access-Control-Max-Age", "3600");

        // OPTIONS preflight 는 바로 200 반환 — 뒤에 JwtFilter 등 타지 않도록
        if ("OPTIONS".equalsIgnoreCase(req.getMethod())) {
            res.setStatus(HttpServletResponse.SC_OK);
            return;
        }

        chain.doFilter(request, response);
    }

    @Override public void init(FilterConfig filterConfig) {}
    @Override public void destroy() {}
}