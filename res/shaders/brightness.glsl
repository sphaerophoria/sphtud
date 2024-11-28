#version 330

in vec2 uv;
out vec4 fragment;
uniform sampler2D input_image;
uniform float brightness = 1.0;

void main()
{
    vec4 tmp = texture(input_image, vec2(uv.x, uv.y));
    fragment = vec4(tmp.xyz * brightness, tmp.w);
}
