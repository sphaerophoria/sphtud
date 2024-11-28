#version 330
in vec2 uv;
out vec4 fragment;
uniform float aspect;
uniform float scale = 1.0;
uniform vec3 foreground = vec3(0.4, 0.4, 0.4);
uniform vec3 background = vec3(0.6, 0.6, 0.6);

void main()
{
    ivec2 biguv = ivec2(uv.x * 100 / scale, uv.y * 100 / scale / aspect);
    bool is_dark = (biguv.x + biguv.y) % 2 == 0;
    fragment = (is_dark) ? vec4(foreground, 1.0) : vec4(background, 1.0);
}
