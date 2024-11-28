#version 330

in vec2 uv;
out vec4 fragment;
uniform sampler2D input_image;
uniform float contrast = 1.0;

void main()
{
    vec4 tmp = texture(input_image, vec2(uv.x, uv.y));
    fragment = vec4((tmp.xyz - 0.5) * contrast + 0.5, tmp.w);
}
