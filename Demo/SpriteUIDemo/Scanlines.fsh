void main() {
    vec4 base = SKDefaultShading();
    float stripe = 0.65 + 0.35 * step(0.5, fract(v_tex_coord.y * 16.0));
    base.rgb *= mix(1.0, stripe, clamp(a_strength, 0.0, 1.0));
    gl_FragColor = base;
}
