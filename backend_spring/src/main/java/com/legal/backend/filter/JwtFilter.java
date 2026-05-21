package com.legal.backend.filter;

import com.legal.backend.util.JwtUtil;
import org.springframework.web.context.WebApplicationContext;
import org.springframework.web.context.support.WebApplicationContextUtils;
import javax.servlet.*;
import javax.servlet.http.*;
import java.io.IOException;

public class JwtFilter implements Filter {
    private JwtUtil jwtUtil;

    @Override
    public void init(FilterConfig filterConfig) {
        WebApplicationContext ctx = WebApplicationContextUtils
                .getWebApplicationContext(filterConfig.getServletContext());
        this.jwtUtil = ctx.getBean(JwtUtil.class);
    }

    @Override
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException {
        HttpServletRequest req = (HttpServletRequest) request;
        HttpServletResponse res = (HttpServletResponse) response;

        if ("OPTIONS".equalsIgnoreCase(req.getMethod())) { chain.doFilter(request, response); return; }

        String authHeader = req.getHeader("Authorization");
        if (authHeader == null || !authHeader.startsWith("Bearer ")) {
            res.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
            res.getWriter().write("토큰이 없습니다."); return;
        }

        String token = authHeader.substring(7);
        if (!jwtUtil.isValid(token)) {
            res.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
            res.getWriter().write("유효하지 않은 토큰입니다."); return;
        }

        req.setAttribute("username", jwtUtil.getUsername(token));
        req.setAttribute("age", jwtUtil.getAge(token));
        chain.doFilter(request, response);
    }
}