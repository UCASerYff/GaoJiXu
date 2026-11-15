"""用户可见的业务错误。不用于掩盖资料损坏。"""


class AppError(Exception):
    def __init__(self, message: str, code: str = "invalid"):
        super().__init__(message)
        self.message = message
        self.code = code
