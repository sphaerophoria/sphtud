#version 330
in vec2 uv;
out vec4 fragment;
uniform float aspect;
uniform vec2 scale = vec2(1.0, 1.0);
uniform vec3 foreground = vec3(0.4, 0.4, 0.4);
uniform vec3 background = vec3(0.6, 0.6, 0.6);

void main()
{
    vec2 scaled_uv = uv / scale;
    ivec2 biguv = ivec2(scaled_uv.x * 100, scaled_uv.y * 100 / aspect);
    bool is_dark = (biguv.x + biguv.y) % 2 == 0;
    fragment = (is_dark) ? vec4(foreground, 1.0) : vec4(background, 1.0);
}
