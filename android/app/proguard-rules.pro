# Правила R8 для релиза. Своих рефлексий в приложении нет, а библиотеки
# (OkHttp, WorkManager, Compose) поставляют собственные consumer-правила.

# ApiToken и адрес сервера читаются из SharedPreferences по строковым ключам —
# сами классы не сериализуются, поэтому ничего дополнительно удерживать не нужно.
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# Tink (через androidx.security:security-crypto) ссылается на аннотации errorprone,
# которых в рантайме нет — это только аннотации, предупреждения R8 по ним не нужны.
-dontwarn com.google.errorprone.annotations.**
